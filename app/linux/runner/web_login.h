#ifndef RUNNER_WEB_LOGIN_H_
#define RUNNER_WEB_LOGIN_H_

#include <flutter_linux/flutter_linux.h>
#include <gtk/gtk.h>

// Serves switchboard/web_login: the bridges' web sign-in pages in a WebKitGTK
// window. What to collect and when to submit is in lib/src/ui/web_login.dart.
void web_login_register(FlView* view, GtkWindow* parent);

#endif  // RUNNER_WEB_LOGIN_H_
