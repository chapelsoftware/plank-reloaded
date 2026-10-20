//
// Copyright (C) 2013 Rico Tzschichholz
//
// This file is part of Plank.
//
// Plank is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// Plank is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program.  If not, see <http://www.gnu.org/licenses/>.
//

namespace Plank {
  /**
   * The default container and controller class for managing application dock items on a dock.
   */
  public class DefaultApplicationDockItemProvider : ApplicationDockItemProvider {
    public DockPreferences Prefs { get; construct; }

    bool current_workspace_only;
    bool monitor_filter_connected = false;
    // Windows we've connected geometry_changed on, keyed by XID.
    Gee.HashMap<ulong, unowned Wnck.Window>? geometry_watched_windows = null;

    /**
     * Creates the default container for dock items.
     *
     * @param prefs the preferences of the dock which owns this provider
     */
    public DefaultApplicationDockItemProvider (DockPreferences prefs, File launchers_dir) {
      Object (Prefs: prefs, LaunchersDir: launchers_dir);
      Text = "DefaultApplicationDockItemProvider";
    }

    construct
    {
      Prefs.notify["CurrentWorkspaceOnly"].connect (handle_setting_changed);
      Prefs.notify["PinnedOnly"].connect (handle_pinned_only_changed);

      WindowControl.get_wnck_screen ().window_opened.connect_after (handle_window_opened);

      current_workspace_only = Prefs.CurrentWorkspaceOnly;

      if (current_workspace_only)
        connect_wnck ();

      update_monitor_filter_connection ();
    }

    ~DefaultApplicationDockItemProvider () {
      Prefs.notify["CurrentWorkspaceOnly"].disconnect (handle_setting_changed);
      Prefs.notify["PinnedOnly"].disconnect (handle_pinned_only_changed);

      WindowControl.get_wnck_screen ().window_opened.disconnect (handle_window_opened);

      if (current_workspace_only)
        disconnect_wnck ();

      if (monitor_filter_connected)
        disconnect_monitor_filter ();
    }

    bool monitor_filter_enabled () {
      return DockController.any_dock_monitor_exclusive ();
    }

    unowned DockController? owning_dock () {
      return Container as DockController;
    }

    int this_dock_monitor_num () {
      unowned DockController? dc = owning_dock ();
      if (dc == null || dc.position_manager == null)
        return -1;
      return dc.position_manager.MonitorNum;
    }

    public void monitor_filter_changed () {
      update_monitor_filter_connection ();
      // The newly-exclusive dock also needs to resync its own transient
      // membership: synthesize the running apps as if they just opened,
      // and recheck visibility.
      if (Prefs.MonitorExclusive)
        match_running_applications ();
      update_visible_elements ();
    }

    void update_monitor_filter_connection () {
      bool want = monitor_filter_enabled ();
      if (want == monitor_filter_connected)
        return;

      if (want)
        connect_monitor_filter ();
      else
        disconnect_monitor_filter ();
    }

    void connect_monitor_filter () {
      if (monitor_filter_connected)
        return;

      geometry_watched_windows = new Gee.HashMap<ulong, unowned Wnck.Window> ();

      unowned Wnck.Screen screen = WindowControl.get_wnck_screen ();
      screen.window_opened.connect_after (handle_window_opened_for_monitor_filter);
      screen.window_closed.connect_after (handle_window_closed_for_monitor_filter);

      foreach (unowned Wnck.Window window in screen.get_windows ())
        watch_window_geometry (window);

      monitor_filter_connected = true;
    }

    void disconnect_monitor_filter () {
      if (!monitor_filter_connected)
        return;

      unowned Wnck.Screen screen = WindowControl.get_wnck_screen ();
      screen.window_opened.disconnect (handle_window_opened_for_monitor_filter);
      screen.window_closed.disconnect (handle_window_closed_for_monitor_filter);

      if (geometry_watched_windows != null) {
        foreach (unowned Wnck.Window window in geometry_watched_windows.values) {
          if (window != null)
            window.geometry_changed.disconnect (handle_window_geometry_changed);
        }
        geometry_watched_windows.clear ();
        geometry_watched_windows = null;
      }

      monitor_filter_connected = false;
    }

    void watch_window_geometry (Wnck.Window? window) {
      if (window == null || geometry_watched_windows == null)
        return;
      ulong xid = window.get_xid ();
      if (geometry_watched_windows.has_key (xid))
        return;
      geometry_watched_windows[xid] = window;
      window.geometry_changed.connect_after (handle_window_geometry_changed);
    }

    [CCode (instance_pos = -1)]
    void handle_window_opened_for_monitor_filter (Wnck.Screen screen, Wnck.Window? window) {
      watch_window_geometry (window);
      recheck_monitor_filter_state ();
    }

    [CCode (instance_pos = -1)]
    void handle_window_closed_for_monitor_filter (Wnck.Screen screen, Wnck.Window? window) {
      if (window != null && geometry_watched_windows != null) {
        ulong xid = window.get_xid ();
        if (geometry_watched_windows.has_key (xid)) {
          window.geometry_changed.disconnect (handle_window_geometry_changed);
          geometry_watched_windows.unset (xid);
        }
      }
      recheck_monitor_filter_state ();
    }

    [CCode (instance_pos = -1)]
    void handle_window_geometry_changed (Wnck.Window window) {
      recheck_monitor_filter_state ();
    }

    // A monitor-exclusive dock gains and loses items as windows move
    // across monitors, so we re-run match_running_applications to pick up
    // newly-arrived apps, then update attach state for everyone.
    void recheck_monitor_filter_state () {
      if (Prefs.MonitorExclusive)
        match_running_applications ();
      update_visible_elements ();
    }

    public void trigger_update_visible_elements (bool update_indicator) {
      internal_update_visible_elements (update_indicator);
    }

    protected void internal_update_visible_elements (bool update_indicator) {
      Logger.verbose ("DefaultDockItemProvider.update_visible_items ()");

      bool monitor_filter = monitor_filter_enabled ();
      int this_monitor = monitor_filter ? this_dock_monitor_num () : -1;
      unowned Wnck.Workspace? active_workspace = Prefs.CurrentWorkspaceOnly
        ? WindowControl.get_wnck_screen ().get_active_workspace () : null;

      foreach (var item in internal_elements) {
        unowned TransientDockItem? transient = (item as TransientDockItem);

        bool attached;
        if (transient == null || transient.App == null) {
          // Pinned items are always attached on their own dock.
          attached = true;
        } else if (Prefs.CurrentWorkspaceOnly) {
          attached = (active_workspace == null
                      || WindowControl.has_window_on_workspace (transient.App, active_workspace));
          if (attached && monitor_filter && this_monitor >= 0)
            attached = WindowControl.has_window_on_monitor (transient.App, this_monitor);
        } else if (monitor_filter && this_monitor >= 0) {
          attached = WindowControl.has_window_on_monitor (transient.App, this_monitor);
        } else {
          attached = WindowControl.has_window (transient.App);
        }

        item.IsAttached = attached;

        if (update_indicator && item.IsAttached) {
          unowned ApplicationDockItem? app_item = (item as ApplicationDockItem);
          if (app_item != null) {
            app_item.external_update_indicator ();
          }
        }
      }

      base.update_visible_elements ();
    }

    protected override void update_visible_elements () {
      internal_update_visible_elements (true);
    }

    /**
     * {@inheritDoc}
     */
    public override void prepare () {
      // A monitor-exclusive dock holds no pinned items; skipping the empty
      // favorites call keeps it from clobbering BAMF's shared favorites set
      // that the primary dock just registered.
      if (!Prefs.MonitorExclusive) {
        // Register the pinned launchers as BAMF favorites in one call;
        // launchers pinned later are registered in connect_element ()
        var favs = new Gee.ArrayList<string> ();

        foreach (var element in internal_elements) {
          unowned ApplicationDockItem? item = (element as ApplicationDockItem);
          if (item != null && !(item is TransientDockItem))
            favs.add (item.Launcher);
        }

        Matcher.get_default ().set_favorites (favs);
      }

      match_running_applications ();
    }

    protected override void app_opened (Bamf.Application app) {
      unowned ApplicationDockItem? found = item_for_application (app);
      if (found != null) {
        found.App = app;
        return;
      }

      // An item with this launcher already tracks another running application,
      // and takes this one's windows too
      var launcher = launcher_for_application (app);
      unowned ApplicationDockItem? owner = (launcher != null ? (item_for_uri (launcher) as ApplicationDockItem) : null);
      if (owner != null) {
        owner.merge_application (app);
        return;
      }

      if (Prefs.PinnedOnly)
        return;

      // A monitor-exclusive dock only hosts transients whose windows are on
      // its monitor; other apps live on another dock. The attach check in
      // update_visible_elements still runs after this and hides items when
      // their windows move away.
      if (Prefs.MonitorExclusive) {
        int this_monitor = this_dock_monitor_num ();
        if (this_monitor < 0 || !WindowControl.has_window_on_monitor (app, this_monitor))
          return;
      }

      // Make sure plank never shows up if we don't want the dock item.
      if (!Prefs.ShowDockItem) {
        string? desktop_file = app.get_desktop_file ();
        if (desktop_file != null && desktop_file.has_suffix ("net.launchpad.plank.desktop")) {
          return;
        }
      }

      var new_item = new TransientDockItem.with_application (app);

      add (new_item);
    }

    void app_closed (DockItem item) {
      if (item is TransientDockItem
          && !(((TransientDockItem) item).has_unity_info ()))
        remove (item);
    }

    void connect_wnck () {
      unowned Wnck.Screen screen = WindowControl.get_wnck_screen ();

      screen.active_window_changed.connect_after (handle_window_changed);
      screen.active_workspace_changed.connect_after (handle_workspace_changed);
      screen.viewports_changed.connect_after (handle_viewports_changed);
      screen.window_closed.connect_after (handle_window_closed);
    }

    void disconnect_wnck () {
      unowned Wnck.Screen screen = WindowControl.get_wnck_screen ();

      screen.active_window_changed.disconnect (handle_window_changed);
      screen.active_workspace_changed.disconnect (handle_workspace_changed);
      screen.viewports_changed.disconnect (handle_viewports_changed);
      screen.window_closed.disconnect (handle_window_closed);
    }

    [CCode (instance_pos = -1)]
    void handle_window_changed (Wnck.Screen screen, Wnck.Window? previous) {
      update_visible_elements ();
    }

    [CCode (instance_pos = -1)]
    void handle_window_closed (Wnck.Screen screen, Wnck.Window? window) {
      update_visible_elements ();
    }

    // BAMF can report an application before Wnck has read its new window, so
    // the item looks windowless until Wnck knows it; check again then
    [CCode (instance_pos = -1)]
    void handle_window_opened (Wnck.Screen screen, Wnck.Window? window) {
      update_visible_elements ();
    }

    [CCode (instance_pos = -1)]
    void handle_workspace_changed (Wnck.Screen screen, Wnck.Workspace? previous) {
      unowned Wnck.Workspace? active_workspace = screen.get_active_workspace ();
      if (active_workspace != null && active_workspace.is_virtual ())
        return;

      update_visible_elements ();
    }

    [CCode (instance_pos = -1)]
    void handle_viewports_changed (Wnck.Screen screen) {
      unowned Wnck.Workspace? active_workspace = screen.get_active_workspace ();
      if (active_workspace != null && !active_workspace.is_virtual ())
        return;

      update_visible_elements ();
    }

    void handle_setting_changed () {
      if (current_workspace_only == Prefs.CurrentWorkspaceOnly)
        return;

      current_workspace_only = Prefs.CurrentWorkspaceOnly;

      if (current_workspace_only)
        connect_wnck ();
      else
        disconnect_wnck ();

      update_visible_elements ();
    }

    void handle_pinned_only_changed () {
      if (Prefs.PinnedOnly)
        remove_transient_items ();
      else
        match_running_applications ();
    }

    void match_running_applications () {
      var transient_items = new Gee.ArrayList<DockElement> ();
      var transient_launchers = new Gee.HashMap<string, TransientDockItem> ();

      int this_monitor = Prefs.MonitorExclusive ? this_dock_monitor_num () : -1;

      // Match running applications to their available dock-items, and add
      // items for the others unless only pinned items are shown. A launcher
      // gets one item, which takes the windows of every application sharing it
      foreach (var app in Matcher.get_default ().active_launchers ()) {
        unowned ApplicationDockItem? found = item_for_application (app);
        if (found != null) {
          found.App = app;
          continue;
        }

        var launcher = launcher_for_application (app);
        if (launcher != null) {
          ApplicationDockItem? owner = (item_for_uri (launcher) as ApplicationDockItem);
          if (owner == null)
            owner = transient_launchers[launcher];

          if (owner != null) {
            owner.merge_application (app);
            continue;
          }
        }

        if (Prefs.PinnedOnly)
          continue;

        if (Prefs.MonitorExclusive) {
          if (this_monitor < 0 || !WindowControl.has_window_on_monitor (app, this_monitor))
            continue;
        }

        var new_item = new TransientDockItem.with_application (app);
        if (launcher != null)
          transient_launchers[launcher] = new_item;

        transient_items.add (new_item);
      }

      add_all (transient_items);
    }

    void remove_transient_items () {
      var transient_items = new Gee.ArrayList<DockElement> ();

      foreach (var element in internal_elements) {
        if (element is TransientDockItem)
          transient_items.add (element);
      }

      remove_all (transient_items);
    }

    protected override void connect_element (DockElement element) {
      base.connect_element (element);

      unowned ApplicationDockItem? appitem = (element as ApplicationDockItem);
      if (appitem != null) {
        appitem.app_closed.connect (app_closed);
        appitem.pin_launcher.connect (pin_item);

        // Launchers loaded at startup were registered together in prepare ()
        if (Container != null && !(appitem is TransientDockItem)) {
          var favs = new Gee.ArrayList<string> ();
          favs.add (appitem.Launcher);
          Matcher.get_default ().set_favorites (favs);
        }
      }
    }

    protected override void disconnect_element (DockElement element) {
      base.disconnect_element (element);

      unowned ApplicationDockItem? appitem = (element as ApplicationDockItem);
      if (appitem != null) {
        appitem.app_closed.disconnect (app_closed);
        appitem.pin_launcher.disconnect (pin_item);
      }
    }

    protected override void handle_item_deleted (DockItem item) {
      unowned Bamf.Application? app = null;
      if (item is ApplicationDockItem)
        app = ((ApplicationDockItem) item).App;

      if (app == null || !app.is_running () || Prefs.PinnedOnly) {
        remove (item);
        return;
      }

      var new_item = new TransientDockItem.with_application (app);
      item.copy_values_to (new_item);
      ((ApplicationDockItem) item).move_merged_applications_to (new_item);

      replace (new_item, item);
    }

    public void pin_item (DockItem item) {
      if (!internal_elements.contains (item)) {
        critical ("Item '%s' does not exist in this DockItemProvider.", item.describe ());
        return;
      }

      Logger.verbose ("DefaultDockItemProvider.pin_item ('%s[%s]')", item.describe (), item.DockItemFilename);

      unowned ApplicationDockItem? app_item = (item as ApplicationDockItem);
      if (app_item == null)
        return;

      // delay automatic add of new dockitems while creating this new one
      delay_items_monitor ();

      if (item is TransientDockItem) {
        var dockitem_file = Factory.item_factory.make_dock_item (item.Launcher, LaunchersDir);
        if (dockitem_file != null) {
          var new_item = new ApplicationDockItem.with_dockitem_file (dockitem_file);
          item.copy_values_to (new_item);
          app_item.move_merged_applications_to (new_item);

          replace (new_item, item);
        }
      } else {
        if (!(app_item.is_running () || app_item.has_unity_info ()))
          remove (item);
        item.delete ();
      }

      resume_items_monitor ();
    }
  }
}
