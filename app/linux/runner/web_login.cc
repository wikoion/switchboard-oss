#include "web_login.h"

#include <webkit2/webkit2.h>

#include <cstring>

// One sign-in window. Dart picks the ID and every callback carries it.
typedef struct {
  gint64 id;
  GtkWidget* window;
  WebKitWebView* view;
  WebKitWebContext* context;
  GCancellable* cancellable;
  int cookies_pending;
  gchar* url;
  // Set when Dart closes the window. Any other end, the close button
  // included, is reported as closed by the user.
  gboolean closing;
} Login;

static FlMethodChannel* channel = nullptr;
static GtkWindow* parent_window = nullptr;
// ID to Login. The table frees them.
static GHashTable* logins = nullptr;

// The call the shared page scripts make on iOS and Android, posted to the
// "sb" message handler here.
static const char* kShim = R"js(
(function() {
  if (window.flutter_inappwebview) return;
  window.flutter_inappwebview = {
    callHandler: function(name) {
      const args = Array.prototype.slice.call(arguments, 1);
      try {
        window.webkit.messageHandlers.sb.postMessage(JSON.stringify({name: name, args: args}));
      } catch (e) {}
      return Promise.resolve();
    },
  };
})();
)js";

static void free_login(gpointer data) {
  Login* login = static_cast<Login*>(data);
  g_object_unref(login->cancellable);
  g_object_unref(login->context);
  g_free(login->url);
  g_free(login);
}

static Login* find_login(gint64 id) {
  return static_cast<Login*>(g_hash_table_lookup(logins, &id));
}

static FlValue* lookup(FlValue* map, const char* key, FlValueType type) {
  FlValue* value = fl_value_lookup_string(map, key);
  return value != nullptr && fl_value_get_type(value) == type ? value : nullptr;
}

static const gchar* lookup_string(FlValue* map, const char* key) {
  FlValue* value = lookup(map, key, FL_VALUE_TYPE_STRING);
  return value == nullptr ? nullptr : fl_value_get_string(value);
}

static gboolean lookup_bool(FlValue* map, const char* key) {
  FlValue* value = lookup(map, key, FL_VALUE_TYPE_BOOL);
  return value != nullptr && fl_value_get_bool(value);
}

static void send(Login* login, const char* method, const char* key,
                 const char* value) {
  g_autoptr(FlValue) args = fl_value_new_map();
  fl_value_set_string_take(args, "id", fl_value_new_int(login->id));
  if (key != nullptr) {
    fl_value_set_string_take(
        args, key,
        value == nullptr ? fl_value_new_null() : fl_value_new_string(value));
  }
  fl_method_channel_invoke_method(channel, method, args, nullptr, nullptr,
                                  nullptr);
}

static void load_changed_cb(WebKitWebView* view, WebKitLoadEvent event,
                            gpointer user_data) {
  if (event != WEBKIT_LOAD_FINISHED) return;
  send(static_cast<Login*>(user_data), "onLoadStop", "url",
       webkit_web_view_get_uri(view));
}

static void uri_changed_cb(WebKitWebView* view, GParamSpec* pspec,
                           gpointer user_data) {
  send(static_cast<Login*>(user_data), "onUrlChanged", "url",
       webkit_web_view_get_uri(view));
}

static void message_cb(WebKitUserContentManager* content,
                       WebKitJavascriptResult* result, gpointer user_data) {
  JSCValue* value = webkit_javascript_result_get_js_value(result);
  if (!jsc_value_is_string(value)) return;
  g_autofree gchar* message = jsc_value_to_string(value);
  send(static_cast<Login*>(user_data), "onMessage", "message", message);
}

// Popups load in the same view, as flutter_inappwebview does on iOS when
// nothing handles onCreateWindow.
static GtkWidget* create_cb(WebKitWebView* view,
                            WebKitNavigationAction* action,
                            gpointer user_data) {
  webkit_web_view_load_request(view, webkit_navigation_action_get_request(action));
  return nullptr;
}

static void destroy_cb(GtkWidget* window, gpointer user_data) {
  Login* login = static_cast<Login*>(user_data);
  // Dart takes this as cancelling the login.
  if (!login->closing) send(login, "onClosed", nullptr, nullptr);
  g_cancellable_cancel(login->cancellable);
  g_signal_handlers_disconnect_by_data(
      webkit_web_view_get_user_content_manager(login->view), login);
  g_signal_handlers_disconnect_by_data(login->view, login);
  g_signal_handlers_disconnect_by_data(login->window, login);
  g_hash_table_remove(logins, &login->id);
}

static void close_login(Login* login) {
  login->closing = TRUE;
  gtk_widget_destroy(login->window);
}

static void cookie_added_cb(GObject* source, GAsyncResult* result,
                            gpointer user_data) {
  webkit_cookie_manager_add_cookie_finish(WEBKIT_COOKIE_MANAGER(source),
                                          result, nullptr);
  Login* login = find_login(static_cast<gint64>(GPOINTER_TO_SIZE(user_data)));
  if (login == nullptr || --login->cookies_pending > 0) return;
  webkit_web_view_load_uri(login->view, login->url);
}

static void add_script(WebKitUserContentManager* content, const gchar* source) {
  g_autoptr(WebKitUserScript) script = webkit_user_script_new(
      source, WEBKIT_USER_CONTENT_INJECT_ALL_FRAMES,
      WEBKIT_USER_SCRIPT_INJECT_AT_DOCUMENT_START, nullptr, nullptr);
  webkit_user_content_manager_add_script(content, script);
}

static void open_login(gint64 id, const gchar* url, FlValue* args) {
  Login* login = g_new0(Login, 1);
  login->id = id;
  login->url = g_strdup(url);
  login->cancellable = g_cancellable_new();
  // A fresh in-memory cookie jar, so a second account on the same network
  // signs in from scratch.
  login->context = webkit_web_context_new_ephemeral();
  WebKitCookieManager* cookies =
      webkit_web_context_get_cookie_manager(login->context);
  webkit_cookie_manager_set_accept_policy(cookies,
                                          WEBKIT_COOKIE_POLICY_ACCEPT_ALWAYS);

  g_autoptr(WebKitUserContentManager) content =
      webkit_user_content_manager_new();
  add_script(content, kShim);
  FlValue* scripts = lookup(args, "scripts", FL_VALUE_TYPE_LIST);
  for (size_t i = 0; scripts != nullptr && i < fl_value_get_length(scripts);
       i++) {
    FlValue* script = fl_value_get_list_value(scripts, i);
    if (fl_value_get_type(script) == FL_VALUE_TYPE_STRING) {
      add_script(content, fl_value_get_string(script));
    }
  }
  webkit_user_content_manager_register_script_message_handler(content, "sb");
  g_signal_connect(content, "script-message-received::sb",
                   G_CALLBACK(message_cb), login);

  login->view = WEBKIT_WEB_VIEW(g_object_new(
      WEBKIT_TYPE_WEB_VIEW, "web-context", login->context,
      "user-content-manager", content, nullptr));
  const gchar* agent = lookup_string(args, "userAgent");
  if (agent != nullptr && agent[0] != '\0') {
    webkit_settings_set_user_agent(webkit_web_view_get_settings(login->view),
                                   agent);
  }
  g_signal_connect(login->view, "load-changed", G_CALLBACK(load_changed_cb),
                   login);
  g_signal_connect(login->view, "notify::uri", G_CALLBACK(uri_changed_cb),
                   login);
  g_signal_connect(login->view, "create", G_CALLBACK(create_cb), login);

  // A hidden login still gets a drawn page, as the 1 px view on iOS does,
  // but nothing on screen. WebKitGTK lets media start by itself, so a
  // hidden page (Reddit, looked at for its video) could play sound unseen;
  // iOS turns that off too.
  if (lookup_bool(args, "hidden")) {
    webkit_settings_set_media_playback_requires_user_gesture(
        webkit_web_view_get_settings(login->view), TRUE);
    // On Wayland an offscreen window has no GL, and WebKit aborts when it
    // can't make a GL context for it.
    webkit_settings_set_hardware_acceleration_policy(
        webkit_web_view_get_settings(login->view),
        WEBKIT_HARDWARE_ACCELERATION_POLICY_NEVER);
    login->window = gtk_offscreen_window_new();
  } else {
    login->window = gtk_window_new(GTK_WINDOW_TOPLEVEL);
    GtkWindow* window = GTK_WINDOW(login->window);
    const gchar* title = lookup_string(args, "title");
    gtk_window_set_title(window, title != nullptr ? title : "Sign in");
    gtk_window_set_icon_name(window, APPLICATION_ID);
    gtk_window_set_transient_for(window, parent_window);
    gtk_window_set_destroy_with_parent(window, TRUE);
    gtk_window_set_default_size(window, 960, 760);
  }
  g_signal_connect(login->window, "destroy", G_CALLBACK(destroy_cb), login);
  gtk_container_add(GTK_CONTAINER(login->window), GTK_WIDGET(login->view));
  g_hash_table_insert(logins, &login->id, login);
  gtk_widget_show_all(login->window);

  // Cookies the bridge passed to continue a login go in before the page
  // loads.
  FlValue* initial = lookup(args, "cookies", FL_VALUE_TYPE_LIST);
  for (size_t i = 0; initial != nullptr && i < fl_value_get_length(initial);
       i++) {
    FlValue* c = fl_value_get_list_value(initial, i);
    if (fl_value_get_type(c) != FL_VALUE_TYPE_MAP) continue;
    const gchar* name = lookup_string(c, "name");
    const gchar* domain = lookup_string(c, "domain");
    if (name == nullptr || domain == nullptr) continue;
    const gchar* value = lookup_string(c, "value");
    const gchar* path = lookup_string(c, "path");
    SoupCookie* cookie =
        soup_cookie_new(name, value != nullptr ? value : "", domain,
                        path != nullptr ? path : "/", -1);
    soup_cookie_set_secure(cookie, lookup_bool(c, "secure"));
    soup_cookie_set_http_only(cookie, lookup_bool(c, "httpOnly"));
    login->cookies_pending++;
    webkit_cookie_manager_add_cookie(cookies, cookie, login->cancellable,
                                     cookie_added_cb,
                                     GSIZE_TO_POINTER(static_cast<gsize>(id)));
    soup_cookie_free(cookie);
  }
  if (login->cookies_pending == 0) {
    webkit_web_view_load_uri(login->view, login->url);
  }
}

typedef struct {
  FlMethodCall* call;
  gchar* host;
} CookieQuery;

// Every cookie for the URL's host and its parent domains, whatever the path,
// as flutter_inappwebview's getCookies(url:) returns on iOS.
static void cookies_cb(GObject* source, GAsyncResult* result,
                       gpointer user_data) {
  CookieQuery* query = static_cast<CookieQuery*>(user_data);
  g_autoptr(FlMethodCall) call = query->call;
  g_autofree gchar* host = query->host;
  g_free(query);
  GList* cookies = webkit_cookie_manager_get_all_cookies_finish(
      WEBKIT_COOKIE_MANAGER(source), result, nullptr);
  g_autoptr(FlValue) list = fl_value_new_list();
  for (GList* l = cookies; l != nullptr; l = l->next) {
    SoupCookie* cookie = static_cast<SoupCookie*>(l->data);
    if (!soup_cookie_domain_matches(cookie, host)) continue;
    FlValue* map = fl_value_new_map();
    fl_value_set_string_take(map, "name",
                             fl_value_new_string(soup_cookie_get_name(cookie)));
    fl_value_set_string_take(
        map, "value", fl_value_new_string(soup_cookie_get_value(cookie)));
    fl_value_set_string_take(
        map, "domain", fl_value_new_string(soup_cookie_get_domain(cookie)));
    fl_value_set_string_take(map, "path",
                             fl_value_new_string(soup_cookie_get_path(cookie)));
    fl_value_set_string_take(
        map, "httpOnly", fl_value_new_bool(soup_cookie_get_http_only(cookie)));
    fl_value_set_string_take(map, "secure",
                             fl_value_new_bool(soup_cookie_get_secure(cookie)));
    fl_value_append_take(list, map);
  }
  g_list_free_full(cookies, reinterpret_cast<GDestroyNotify>(soup_cookie_free));
  fl_method_call_respond_success(call, list, nullptr);
}

// Strings, numbers and booleans as they are; anything else as JSON.
static FlValue* js_to_value(JSCValue* value) {
  if (jsc_value_is_string(value)) {
    g_autofree gchar* s = jsc_value_to_string(value);
    return fl_value_new_string(s);
  }
  if (jsc_value_is_boolean(value)) {
    return fl_value_new_bool(jsc_value_to_boolean(value));
  }
  if (jsc_value_is_number(value)) {
    return fl_value_new_float(jsc_value_to_double(value));
  }
  if (jsc_value_is_null(value) || jsc_value_is_undefined(value)) {
    return fl_value_new_null();
  }
  g_autofree gchar* json = jsc_value_to_json(value, 0);
  return json == nullptr ? fl_value_new_null() : fl_value_new_string(json);
}

static void evaluate_cb(GObject* source, GAsyncResult* result,
                        gpointer user_data) {
  g_autoptr(FlMethodCall) call = FL_METHOD_CALL(user_data);
  g_autoptr(JSCValue) value = webkit_web_view_evaluate_javascript_finish(
      WEBKIT_WEB_VIEW(source), result, nullptr);
  g_autoptr(FlValue) out =
      value == nullptr ? fl_value_new_null() : js_to_value(value);
  fl_method_call_respond_success(call, out, nullptr);
}

static void method_call_cb(FlMethodChannel* self, FlMethodCall* call,
                           gpointer user_data) {
  const gchar* method = fl_method_call_get_name(call);
  FlValue* args = fl_method_call_get_args(call);
  FlValue* id_value = args != nullptr && fl_value_get_type(args) == FL_VALUE_TYPE_MAP
                          ? lookup(args, "id", FL_VALUE_TYPE_INT)
                          : nullptr;
  if (id_value == nullptr) {
    fl_method_call_respond_error(call, "bad_args", "Expected an id", nullptr,
                                 nullptr);
    return;
  }
  gint64 id = fl_value_get_int(id_value);
  Login* login = find_login(id);

  if (strcmp(method, "open") == 0) {
    const gchar* url = lookup_string(args, "url");
    if (url == nullptr) {
      fl_method_call_respond_error(call, "bad_args", "Expected a url", nullptr,
                                   nullptr);
      return;
    }
    if (login != nullptr) close_login(login);
    open_login(id, url, args);
    fl_method_call_respond_success(call, nullptr, nullptr);
  } else if (strcmp(method, "close") == 0) {
    if (login != nullptr) close_login(login);
    fl_method_call_respond_success(call, nullptr, nullptr);
  } else if (strcmp(method, "getCookies") == 0) {
    const gchar* url = lookup_string(args, "url");
    g_autoptr(GUri) uri =
        url == nullptr ? nullptr : g_uri_parse(url, G_URI_FLAGS_NONE, nullptr);
    const gchar* host = uri == nullptr ? nullptr : g_uri_get_host(uri);
    if (login == nullptr || host == nullptr) {
      fl_method_call_respond_success(call, nullptr, nullptr);
      return;
    }
    CookieQuery* query = g_new0(CookieQuery, 1);
    query->call = FL_METHOD_CALL(g_object_ref(call));
    query->host = g_strdup(host);
    webkit_cookie_manager_get_all_cookies(
        webkit_web_context_get_cookie_manager(login->context),
        login->cancellable, cookies_cb, query);
  } else if (strcmp(method, "evaluateJavascript") == 0) {
    const gchar* source = lookup_string(args, "source");
    if (login == nullptr || source == nullptr) {
      fl_method_call_respond_success(call, nullptr, nullptr);
      return;
    }
    webkit_web_view_evaluate_javascript(login->view, source, -1, nullptr,
                                        nullptr, login->cancellable,
                                        evaluate_cb, g_object_ref(call));
  } else {
    fl_method_call_respond_not_implemented(call, nullptr);
  }
}

void web_login_register(FlView* view, GtkWindow* parent) {
  parent_window = parent;
  logins = g_hash_table_new_full(g_int64_hash, g_int64_equal, nullptr,
                                 free_login);
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  channel = fl_method_channel_new(
      fl_engine_get_binary_messenger(fl_view_get_engine(view)),
      "switchboard/web_login", FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(channel, method_call_cb, nullptr,
                                            nullptr);
}
