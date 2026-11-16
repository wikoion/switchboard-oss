//! The camera, read with V4L2 on its own thread. Its frames go to RingRTC's
//! video source, and a small copy is kept for the preview. Only NV12 and
//! YUYV cameras so far; MJPEG-only ones aren't used.

use std::{
    borrow::Cow,
    io,
    sync::{
        atomic::{AtomicBool, Ordering},
        Arc,
    },
    thread::{self, JoinHandle},
    time::Duration,
};

use anyhow::{anyhow, bail, Context, Result};
use ringrtc::webrtc::media::{VideoFrame, VideoPixelFormat, VideoSource};
use v4l::{buffer::Type, io::traits::CaptureStream, prelude::*, video::Capture, Format, FourCC};

use super::video::{fit, FrameSlot};

/// What the camera is asked for. It gives the nearest size it has.
const WANTED: (u32, u32) = (1280, 720);
/// The preview is drawn small.
const PREVIEW: (u32, u32) = (640, 360);
const NV12: FourCC = FourCC { repr: *b"NV12" };
const YUYV: FourCC = FourCC { repr: *b"YUYV" };
/// A camera can take a while to give its first frame.
const FIRST_FRAME: Duration = Duration::from_secs(3);
/// How often the thread checks it should stop.
const POLL: Duration = Duration::from_millis(500);

pub(super) struct Camera {
    stop: Arc<AtomicBool>,
    thread: Option<JoinHandle<()>>,
}

impl Camera {
    /// Opens the first camera that gives NV12 or YUYV and starts sending its
    /// frames. Waits for the first, so a busy camera fails here.
    pub(super) fn start(source: VideoSource, preview: FrameSlot) -> Result<Self> {
        let (device, format) = open()?;
        tracing::debug!("camera: {}x{} {}, stride {}", format.width, format.height, format.fourcc, format.stride);
        let mut stream = MmapStream::with_buffers(&device, Type::VideoCapture, 4).context("camera buffers")?;
        stream.set_timeout(FIRST_FRAME);
        let (data, meta) = stream.next().map_err(busy).context("camera")?;
        send(&format, &data[..meta.bytesused as usize], &source, &preview)?;
        stream.set_timeout(POLL);

        let stop = Arc::new(AtomicBool::new(false));
        let stopping = stop.clone();
        let thread = thread::Builder::new().name("camera".into()).spawn(move || {
            // The stream holds the device open; keep both until it stops.
            let _device = device;
            while !stopping.load(Ordering::SeqCst) {
                let sent = match stream.next() {
                    Ok((data, meta)) => send(&format, &data[..meta.bytesused as usize], &source, &preview),
                    Err(e) if e.kind() == io::ErrorKind::TimedOut => continue,
                    Err(e) => Err(e.into()),
                };
                if let Err(e) = sent {
                    tracing::warn!("camera: {e:#}");
                    break;
                }
            }
        })?;
        Ok(Camera { stop, thread: Some(thread) })
    }
}

impl Drop for Camera {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::SeqCst);
        if let Some(thread) = self.thread.take() {
            let _ = thread.join();
        }
    }
}

/// The first `/dev/video*` that captures NV12 or YUYV, set to its nearest
/// size to [`WANTED`].
fn open() -> Result<(Device, Format)> {
    let mut nodes = v4l::context::enum_devices();
    nodes.sort_by_key(|node| node.index());
    for node in nodes {
        let Ok(device) = Device::with_path(node.path()) else {
            continue;
        };
        let Ok(formats) = device.enum_formats() else {
            continue;
        };
        let Some(fourcc) = [NV12, YUYV].into_iter().find(|f| formats.iter().any(|d| d.fourcc == *f)) else {
            continue;
        };
        let format = device.set_format(&Format::new(WANTED.0, WANTED.1, fourcc))?;
        if format.fourcc != fourcc {
            continue;
        }
        return Ok((device, format));
    }
    bail!("no camera found that gives NV12 or YUYV")
}

/// v4l2loopback lets one app at a time read the camera.
fn busy(e: io::Error) -> anyhow::Error {
    const EBUSY: i32 = 16;
    if e.raw_os_error() == Some(EBUSY) {
        return anyhow!("the camera is in use by another app");
    }
    e.into()
}

fn send(format: &Format, data: &[u8], source: &VideoSource, preview: &FrameSlot) -> Result<()> {
    let frame = to_frame(format, data)?;
    let (width, height) = fit(frame.width(), frame.height(), PREVIEW.0, PREVIEW.1);
    preview.put(frame.scale(width, height));
    source.push_frame(frame);
    Ok(())
}

fn to_frame(format: &Format, data: &[u8]) -> Result<VideoFrame> {
    let (width, height, stride) = (format.width, format.height, format.stride);
    if width % 2 != 0 || height % 2 != 0 {
        bail!("odd camera size {width}x{height}");
    }
    if format.fourcc == NV12 {
        let packed = pack_nv12(data, width as usize, height as usize, stride as usize)?;
        Ok(VideoFrame::copy_from_slice(width, height, VideoPixelFormat::Nv12, &packed))
    } else {
        let i420 = yuyv_to_i420(data, width as usize, height as usize, stride as usize)?;
        Ok(VideoFrame::copy_from_slice(width, height, VideoPixelFormat::I420, &i420))
    }
}

/// NV12 with each row `width` bytes, as RingRTC wants it. Cameras may pad
/// rows out to `stride`.
fn pack_nv12(data: &[u8], width: usize, height: usize, stride: usize) -> Result<Cow<'_, [u8]>> {
    let rows = height + height / 2;
    if data.len() < stride * (rows - 1) + width {
        bail!("short NV12 frame: {} bytes", data.len());
    }
    if stride == width {
        return Ok(Cow::Borrowed(&data[..width * rows]));
    }
    let mut packed = Vec::with_capacity(width * rows);
    for row in 0..rows {
        packed.extend_from_slice(&data[row * stride..row * stride + width]);
    }
    Ok(Cow::Owned(packed))
}

/// YUYV (Y0 U Y1 V per two pixels) to I420, taking colour from even rows.
fn yuyv_to_i420(data: &[u8], width: usize, height: usize, stride: usize) -> Result<Vec<u8>> {
    if data.len() < stride * (height - 1) + width * 2 {
        bail!("short YUYV frame: {} bytes", data.len());
    }
    let (chroma_width, chroma_height) = (width / 2, height / 2);
    let mut out = vec![0; width * height + 2 * chroma_width * chroma_height];
    let (y_plane, chroma) = out.split_at_mut(width * height);
    let (u_plane, v_plane) = chroma.split_at_mut(chroma_width * chroma_height);
    for row in 0..height {
        let line = &data[row * stride..row * stride + width * 2];
        for (x, pair) in line.as_chunks::<4>().0.iter().enumerate() {
            y_plane[row * width + x * 2] = pair[0];
            y_plane[row * width + x * 2 + 1] = pair[2];
            if row % 2 == 0 {
                u_plane[row / 2 * chroma_width + x] = pair[1];
                v_plane[row / 2 * chroma_width + x] = pair[3];
            }
        }
    }
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn nv12_rows_lose_their_padding() {
        // 2x2: two Y rows and one UV row, each padded to 4 bytes.
        let data = [1, 2, 0, 0, 3, 4, 0, 0, 5, 6, 0, 0];
        assert_eq!(&*pack_nv12(&data, 2, 2, 4).unwrap(), &[1, 2, 3, 4, 5, 6]);
        assert!(matches!(pack_nv12(&data[..6], 2, 2, 2).unwrap(), Cow::Borrowed(_)));
        assert!(pack_nv12(&data[..5], 2, 2, 2).is_err());
    }

    #[test]
    fn yuyv_becomes_i420() {
        // 2x2: row 0 is Y 1,2 with U 10 V 20; row 1 is Y 3,4 with U 11 V 21.
        let data = [1, 10, 2, 20, 3, 11, 4, 21];
        assert_eq!(yuyv_to_i420(&data, 2, 2, 4).unwrap(), vec![1, 2, 3, 4, 10, 20]);
    }

    /// Reads real frames. Ignored by default: it needs a camera no other app
    /// is using. A v4l2loopback relay gives one placeholder frame at once,
    /// then nothing for about 3.5 s while the camera starts.
    #[test]
    #[ignore = "needs a free camera"]
    fn camera_gives_frames() -> Result<()> {
        let _ = tracing_subscriber::fmt().with_test_writer().with_env_filter("switchboard_core=debug").try_init();
        let factory = ringrtc::webrtc::peer_connection_factory::PeerConnectionFactory::new(
            &ringrtc::webrtc::peer_connection_factory::AudioConfig::default(),
            false,
            "",
            None,
        )?;
        let source = factory.create_outgoing_video_source()?;
        let preview = FrameSlot::default();
        let camera = Camera::start(source, preview.clone())?;
        let mut frames = 0;
        for _ in 0..250 {
            thread::sleep(Duration::from_millis(40));
            if let Some(frame) = preview.take() {
                assert!(frame.width() <= PREVIEW.0 && frame.height() <= PREVIEW.1);
                assert!(super::super::video::to_rgba(frame, PREVIEW.0, PREVIEW.1).is_some());
                frames += 1;
            }
            if frames == 10 {
                break;
            }
        }
        drop(camera);
        assert_eq!(frames, 10, "only {frames} preview frames in 10 s");
        Ok(())
    }
}
