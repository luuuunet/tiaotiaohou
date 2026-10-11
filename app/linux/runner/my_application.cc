#include "my_application.h"

#include <flutter_linux/flutter_linux.h>

#include <cstring>
#include <dlfcn.h>
#include <glib-unix.h>

#include "flutter/generated_plugin_registrant.h"

struct _MyApplication {
  GtkApplication parent_instance;
  char** dart_entrypoint_arguments;
  GtkWindow* window;
  FlMethodChannel* channel;
  gboolean quitting;
  gboolean quiet;
  guint sleep_watch;
  GDBusConnection* system_bus;
  void* tray_lib;
  void* indicator;
  void (*tray_set_title)(void*, const char*);
  GtkWidget* tray_menu;
};

G_DEFINE_TYPE(MyApplication, my_application, GTK_TYPE_APPLICATION)

template <typename T>
static T load_symbol(void* handle, const char* name) {
  T fn = nullptr;
  void* symbol = dlsym(handle, name);
  memcpy(&fn, &symbol, sizeof(fn));
  return fn;
}

static void invoke_dart(MyApplication* self, const char* method) {
  if (self->channel == nullptr) return;
  fl_method_channel_invoke_method(self->channel, method, nullptr, nullptr, nullptr, nullptr);
}

static gboolean quit_idle(gpointer user_data) {
  auto* self = MY_APPLICATION(user_data);
  self->quitting = TRUE;
  g_application_quit(G_APPLICATION(self));
  return G_SOURCE_REMOVE;
}

static void show_window(MyApplication* self) {
  if (self->window == nullptr) return;
  gtk_widget_show(GTK_WIDGET(self->window));
  gtk_window_deiconify(self->window);
  gtk_window_present(self->window);
}

static void hide_window(MyApplication* self) {
  if (self->window == nullptr) return;
  gtk_widget_hide(GTK_WIDGET(self->window));
}

static void respond_ok(FlMethodCall* method_call) {
  g_autoptr(GError) error = nullptr;
  if (!fl_method_call_respond_success(method_call, nullptr, &error) && error != nullptr) {
    g_warning("%s", error->message);
  }
}

static guint32 last_press_time = 0;

static gboolean on_button_press(GtkWidget*, GdkEventButton* event, gpointer) {
  if (event->button == GDK_BUTTON_PRIMARY) last_press_time = event->time;
  return FALSE;
}

static void begin_drag(GtkWindow* window) {
  GdkWindow* gdk = gtk_widget_get_window(GTK_WIDGET(window));
  if (gdk == nullptr) return;
  GdkDisplay* display = gdk_window_get_display(gdk);
  GdkSeat* seat = gdk_display_get_default_seat(display);
  if (seat == nullptr) return;
  GdkDevice* pointer = gdk_seat_get_pointer(seat);
  if (pointer == nullptr) return;
  gint x = 0;
  gint y = 0;
  gdk_device_get_position(pointer, nullptr, &x, &y);
  guint32 time = last_press_time != 0 ? last_press_time : gtk_get_current_event_time();
  gtk_window_begin_move_drag(window, GDK_BUTTON_PRIMARY, x, y, time);
}

static const char* map_string(FlValue* args, const char* key) {
  if (args == nullptr || fl_value_get_type(args) != FL_VALUE_TYPE_MAP) return nullptr;
  FlValue* value = fl_value_lookup_string(args, key);
  if (value == nullptr || fl_value_get_type(value) != FL_VALUE_TYPE_STRING) return nullptr;
  return fl_value_get_string(value);
}

static void host_method_call(FlMethodChannel*, FlMethodCall* method_call, gpointer user_data) {
  auto* self = MY_APPLICATION(user_data);
  const gchar* name = fl_method_call_get_name(method_call);
  if (g_strcmp0(name, "minimize") == 0) {
    if (self->window != nullptr) gtk_window_iconify(self->window);
    respond_ok(method_call);
    return;
  }
  if (g_strcmp0(name, "zoom") == 0) {
    if (self->window != nullptr) {
      if (gtk_window_is_maximized(self->window)) {
        gtk_window_unmaximize(self->window);
      } else {
        gtk_window_maximize(self->window);
      }
    }
    respond_ok(method_call);
    return;
  }
  if (g_strcmp0(name, "drag") == 0) {
    if (self->window != nullptr) begin_drag(self->window);
    respond_ok(method_call);
    return;
  }
  if (g_strcmp0(name, "hideToTray") == 0 || g_strcmp0(name, "close") == 0) {
    hide_window(self);
    respond_ok(method_call);
    return;
  }
  if (g_strcmp0(name, "showWindow") == 0) {
    show_window(self);
    respond_ok(method_call);
    return;
  }
  if (g_strcmp0(name, "quit") == 0) {
    respond_ok(method_call);
    g_idle_add(quit_idle, self);
    return;
  }
  if (g_strcmp0(name, "setTrayTip") == 0) {
    const char* text = map_string(fl_method_call_get_args(method_call), "text");
    if (text != nullptr && self->indicator != nullptr && self->tray_set_title != nullptr) {
      self->tray_set_title(self->indicator, text);
    }
    respond_ok(method_call);
    return;
  }
  if (g_strcmp0(name, "start") == 0 || g_strcmp0(name, "stop") == 0 || g_strcmp0(name, "notify") == 0) {
    respond_ok(method_call);
    return;
  }
  g_autoptr(GError) error = nullptr;
  if (!fl_method_call_respond_not_implemented(method_call, &error) && error != nullptr) {
    g_warning("%s", error->message);
  }
}

static void on_tray_show(GtkMenuItem*, gpointer user_data) {
  auto* self = MY_APPLICATION(user_data);
  show_window(self);
  invoke_dart(self, "trayShow");
}

static void on_tray_toggle(GtkMenuItem*, gpointer user_data) {
  invoke_dart(MY_APPLICATION(user_data), "trayToggle");
}

static void on_tray_quit(GtkMenuItem*, gpointer user_data) {
  invoke_dart(MY_APPLICATION(user_data), "trayQuit");
}

static GtkWidget* tray_item(const char* label, GCallback callback, gpointer data) {
  GtkWidget* item = gtk_menu_item_new_with_label(label);
  g_signal_connect(item, "activate", callback, data);
  gtk_widget_show(item);
  return item;
}

static char* executable_dir() {
  g_autofree char* exe = g_file_read_link("/proc/self/exe", nullptr);
  if (exe == nullptr) return nullptr;
  return g_path_get_dirname(exe);
}

static void setup_tray(MyApplication* self, const char* icon_path) {
  const char* libs[] = {"libayatana-appindicator3.so.1", "libappindicator3.so.1", nullptr};
  void* handle = nullptr;
  for (int i = 0; libs[i] != nullptr; i++) {
    handle = dlopen(libs[i], RTLD_NOW | RTLD_LOCAL);
    if (handle != nullptr) break;
  }
  if (handle == nullptr) return;
  auto new_indicator = load_symbol<void* (*)(const char*, const char*, int)>(handle, "app_indicator_new");
  auto set_status = load_symbol<void (*)(void*, int)>(handle, "app_indicator_set_status");
  auto set_menu = load_symbol<void (*)(void*, GtkMenu*)>(handle, "app_indicator_set_menu");
  auto set_icon = load_symbol<void (*)(void*, const char*)>(handle, "app_indicator_set_icon");
  auto set_icon_full = load_symbol<void (*)(void*, const char*, const char*)>(handle, "app_indicator_set_icon_full");
  auto set_title = load_symbol<void (*)(void*, const char*)>(handle, "app_indicator_set_title");
  if (new_indicator == nullptr || set_status == nullptr || set_menu == nullptr) {
    dlclose(handle);
    return;
  }
  void* indicator = new_indicator("dev.rsq.rsq", "network-vpn", 0);
  if (indicator == nullptr) {
    dlclose(handle);
    return;
  }
  if (icon_path != nullptr && set_icon_full != nullptr) {
    set_icon_full(indicator, icon_path, "跳跳猴");
  } else if (icon_path != nullptr && set_icon != nullptr) {
    set_icon(indicator, icon_path);
  }
  if (set_title != nullptr) set_title(indicator, "跳跳猴");

  GtkWidget* menu = gtk_menu_new();
  gtk_menu_shell_append(GTK_MENU_SHELL(menu), tray_item("显示窗口", G_CALLBACK(on_tray_show), self));
  gtk_menu_shell_append(GTK_MENU_SHELL(menu), tray_item("连接 / 断开", G_CALLBACK(on_tray_toggle), self));
  GtkWidget* sep = gtk_separator_menu_item_new();
  gtk_widget_show(sep);
  gtk_menu_shell_append(GTK_MENU_SHELL(menu), sep);
  gtk_menu_shell_append(GTK_MENU_SHELL(menu), tray_item("退出", G_CALLBACK(on_tray_quit), self));
  set_menu(indicator, GTK_MENU(menu));
  set_status(indicator, 1);

  self->tray_lib = handle;
  self->indicator = indicator;
  self->tray_set_title = set_title;
  self->tray_menu = menu;
  g_object_ref_sink(menu);
}

static gboolean on_delete_event(GtkWidget*, GdkEvent*, gpointer user_data) {
  auto* self = MY_APPLICATION(user_data);
  if (self->quitting) return FALSE;
  invoke_dart(self, "trayQuit");
  return TRUE;
}

static void first_frame_cb(MyApplication* self, FlView* view) {
  GtkWidget* window = gtk_widget_get_toplevel(GTK_WIDGET(view));
  if (self->quiet) {
    gtk_widget_hide(window);
    return;
  }
  gtk_widget_show(window);
}

static gboolean args_have_quiet(char** args) {
  if (args == nullptr) return FALSE;
  for (int i = 0; args[i] != nullptr; i++) {
    if (g_strcmp0(args[i], "--quiet") == 0) return TRUE;
  }
  return FALSE;
}

static void my_application_activate(GApplication* application) {
  auto* self = MY_APPLICATION(application);
  if (self->window != nullptr) {
    show_window(self);
    return;
  }
  self->quiet = args_have_quiet(self->dart_entrypoint_arguments);

  GtkWindow* window = GTK_WINDOW(gtk_application_window_new(GTK_APPLICATION(application)));
  self->window = window;
  gtk_window_set_title(window, "跳跳猴");
  gtk_window_set_decorated(window, FALSE);
  gtk_window_set_default_size(window, 1080, 700);
  gtk_widget_set_size_request(GTK_WIDGET(window), 720, 480);
  g_signal_connect(window, "delete-event", G_CALLBACK(on_delete_event), self);

  g_autofree char* dir = executable_dir();
  g_autofree char* icon = nullptr;
  if (dir != nullptr) {
    icon = g_build_filename(dir, "data", "flutter_assets", "assets", "logo.png", nullptr);
    if (g_file_test(icon, G_FILE_TEST_EXISTS)) {
      if (!gtk_window_set_icon_from_file(window, icon, nullptr)) {
        g_warning("window icon failed");
      }
      if (!gtk_window_set_default_icon_from_file(icon, nullptr)) {
        g_warning("default icon failed");
      }
    }
  }

  g_autoptr(FlDartProject) project = fl_dart_project_new();
  fl_dart_project_set_dart_entrypoint_arguments(project, self->dart_entrypoint_arguments);

  FlView* view = fl_view_new(project);
  GdkRGBA background;
  gdk_rgba_parse(&background, "#F7F6F1");
  fl_view_set_background_color(view, &background);
  gtk_widget_show(GTK_WIDGET(view));
  gtk_container_add(GTK_CONTAINER(window), GTK_WIDGET(view));

  g_signal_connect(view, "button-press-event", G_CALLBACK(on_button_press), nullptr);
  g_signal_connect_swapped(view, "first-frame", G_CALLBACK(first_frame_cb), self);
  gtk_widget_realize(GTK_WIDGET(view));
  fl_register_plugins(FL_PLUGIN_REGISTRY(view));

  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  self->channel = fl_method_channel_new(fl_engine_get_binary_messenger(fl_view_get_engine(view)), "dev.rsq/host",
                                         FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(self->channel, host_method_call, self, nullptr);
  const char* tray_icon = nullptr;
  if (icon != nullptr && g_file_test(icon, G_FILE_TEST_EXISTS)) tray_icon = icon;
  setup_tray(self, tray_icon);
  gtk_widget_grab_focus(GTK_WIDGET(view));
}

static gboolean my_application_local_command_line(GApplication* application, gchar*** arguments, int* exit_status) {
  auto* self = MY_APPLICATION(application);
  self->dart_entrypoint_arguments = g_strdupv(*arguments + 1);

  g_autoptr(GError) error = nullptr;
  if (!g_application_register(application, nullptr, &error)) {
    g_warning("Failed to register: %s", error->message);
    *exit_status = 1;
    return TRUE;
  }

  g_application_activate(application);
  *exit_status = 0;
  return TRUE;
}

static gboolean on_unix_signal(gpointer user_data) {
  auto* self = MY_APPLICATION(user_data);
  if (self->quitting || self->channel == nullptr) {
    g_application_quit(G_APPLICATION(self));
    return G_SOURCE_REMOVE;
  }
  invoke_dart(self, "trayQuit");
  g_timeout_add(1500, quit_idle, self);
  return G_SOURCE_REMOVE;
}

static void on_prepare_for_sleep(GDBusConnection*,
                                  const gchar*,
                                  const gchar*,
                                  const gchar*,
                                  const gchar*,
                                  GVariant* parameters,
                                  gpointer user_data) {
  auto* self = MY_APPLICATION(user_data);
  gboolean sleeping = TRUE;
  if (parameters != nullptr) g_variant_get(parameters, "(b)", &sleeping);
  if (sleeping) return;
  invoke_dart(self, "sessionUnlock");
  invoke_dart(self, "networkChanged");
}

static void my_application_startup(GApplication* application) {
  G_APPLICATION_CLASS(my_application_parent_class)->startup(application);
  auto* self = MY_APPLICATION(application);
  g_unix_signal_add(SIGTERM, on_unix_signal, self);
  g_unix_signal_add(SIGINT, on_unix_signal, self);
  self->system_bus = g_bus_get_sync(G_BUS_TYPE_SYSTEM, nullptr, nullptr);
  if (self->system_bus == nullptr) return;
  self->sleep_watch = g_dbus_connection_signal_subscribe(self->system_bus, "org.freedesktop.login1",
                                                          "org.freedesktop.login1.Manager", "PrepareForSleep",
                                                          "/org/freedesktop/login1", nullptr, G_DBUS_SIGNAL_FLAGS_NONE,
                                                          on_prepare_for_sleep, self, nullptr);
}

static void my_application_shutdown(GApplication* application) {
  auto* self = MY_APPLICATION(application);
  self->quitting = TRUE;
  if (self->system_bus != nullptr && self->sleep_watch != 0) {
    g_dbus_connection_signal_unsubscribe(self->system_bus, self->sleep_watch);
    self->sleep_watch = 0;
  }
  g_clear_object(&self->system_bus);
  G_APPLICATION_CLASS(my_application_parent_class)->shutdown(application);
}

static void my_application_dispose(GObject* object) {
  auto* self = MY_APPLICATION(object);
  g_clear_pointer(&self->dart_entrypoint_arguments, g_strfreev);
  if (self->channel != nullptr) {
    g_object_unref(self->channel);
    self->channel = nullptr;
  }
  G_OBJECT_CLASS(my_application_parent_class)->dispose(object);
}

static void my_application_class_init(MyApplicationClass* klass) {
  G_APPLICATION_CLASS(klass)->activate = my_application_activate;
  G_APPLICATION_CLASS(klass)->local_command_line = my_application_local_command_line;
  G_APPLICATION_CLASS(klass)->startup = my_application_startup;
  G_APPLICATION_CLASS(klass)->shutdown = my_application_shutdown;
  G_OBJECT_CLASS(klass)->dispose = my_application_dispose;
}

static void my_application_init(MyApplication* self) {
  self->window = nullptr;
  self->channel = nullptr;
  self->quitting = FALSE;
  self->quiet = FALSE;
  self->sleep_watch = 0;
  self->system_bus = nullptr;
  self->tray_lib = nullptr;
  self->indicator = nullptr;
  self->tray_set_title = nullptr;
  self->tray_menu = nullptr;
}

MyApplication* my_application_new() {
  g_set_prgname(APPLICATION_ID);
  g_set_application_name("跳跳猴");
#if GLIB_CHECK_VERSION(2, 74, 0)
  GApplicationFlags flags = G_APPLICATION_DEFAULT_FLAGS;
#else
  GApplicationFlags flags = G_APPLICATION_FLAGS_NONE;
#endif
  return MY_APPLICATION(g_object_new(my_application_get_type(), "application-id", APPLICATION_ID, "flags", flags, nullptr));
}
