//! Video frames between RingRTC and the screen. Each side keeps only its
//! newest frame, and the app takes it when it draws, as Signal Desktop does,
//! so a slow screen skips frames instead of falling behind.

use std::sync::{Arc, Mutex as StdMutex};

use ringrtc::{
    lite::sfu::DemuxId,
    webrtc::media::{VideoFrame, VideoSink},
};

use crate::api::calls::CallFrame;

/// The newest frame from the contact or the camera.
#[derive(Clone, Default)]
pub(super) struct FrameSlot(Arc<StdMutex<Option<VideoFrame>>>);

impl FrameSlot {
    pub(super) fn put(&self, frame: VideoFrame) {
        *self.0.lock().unwrap() = Some(frame);
    }

    pub(super) fn take(&self) -> Option<VideoFrame> {
        self.0.lock().unwrap().take()
    }

    pub(super) fn clear(&self) {
        self.take();
    }
}

// RingRTC hands the contact's frames here.
impl VideoSink for FrameSlot {
    fn on_video_frame(&self, _: DemuxId, frame: VideoFrame) {
        self.put(frame);
    }

    fn box_clone(&self) -> Box<dyn VideoSink> {
        Box::new(self.clone())
    }
}

/// `frame` upright, as RGBA, shrunk to fit `max_width` by `max_height`.
pub(super) fn to_rgba(frame: VideoFrame, max_width: u32, max_height: u32) -> Option<CallFrame> {
    let frame = frame.apply_rotation();
    let (width, height) = fit(frame.width(), frame.height(), max_width, max_height);
    let frame = if (width, height) == (frame.width(), frame.height()) { frame } else { frame.scale(width, height) };
    let mut rgba = vec![0; width as usize * height as usize * 4];
    frame.to_rgba(&mut rgba).then_some(CallFrame { width, height, rgba })
}

/// The largest even size no bigger than the box with the frame's shape.
pub(super) fn fit(width: u32, height: u32, max_width: u32, max_height: u32) -> (u32, u32) {
    if width == 0 || height == 0 || (width <= max_width && height <= max_height) {
        return (width, height);
    }
    let scale = f64::min(max_width as f64 / width as f64, max_height as f64 / height as f64);
    let even = |n: u32| (((n as f64 * scale) as u32) & !1).max(2);
    (even(width), even(height))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn frames_shrink_to_fit_and_keep_their_shape() {
        assert_eq!(fit(1280, 720, 1920, 1080), (1280, 720));
        assert_eq!(fit(1920, 1080, 640, 640), (640, 360));
        assert_eq!(fit(720, 1280, 640, 360), (202, 360));
        assert_eq!(fit(0, 0, 640, 360), (0, 0));
    }
}
