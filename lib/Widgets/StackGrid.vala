//
// Copyright (C) 2024 Plank Reloaded Developers
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program.  If not, see <http://www.gnu.org/licenses/>.
//

namespace Plank {
  /**
   * Something to show in a {@link StackGrid}: a name, an icon and what
   * happens when it is chosen.
   */
  public class StackGridEntry : GLib.Object {
    public string name { get; construct; }
    public string icon { get; construct; }

    /**
     * The entry was chosen; the grid has already closed.
     */
    public signal void activated ();

    public StackGridEntry (string name, string icon) {
      GLib.Object (name : name, icon : icon);
    }
  }

  /**
   * A macOS-style stack grid: a translucent rounded panel above a dock item
   * with an arrow pointing at it, holding entries (applications, a folder's
   * files) as large icons with their names in a scrollable grid. A search
   * field at the top filters the grid as you type, and Enter chooses the
   * first match. Choosing an entry, pressing Escape on an empty search or
   * activating any other window closes it.
   *
   * It is an ordinary undecorated window that takes keyboard focus, not a
   * popup holding a keyboard grab, so global shortcuts such as Print Screen
   * keep working while it is open. It closes when the window manager makes
   * another window active rather than on focus-out, because a global
   * shortcut's key grab also sends focus-out and would close it before a
   * screenshot could include it.
   *
   * The window gets its own WM class so a compositor can blur what is behind
   * it, and its shape follows the panel and arrow so the blur does too.
   */
  public class StackGrid : Gtk.Window {
    const int ICON_SIZE = 64;
    const int CELL_WIDTH = 104;
    const int CELL_HEIGHT = 100;
    const int MAX_COLUMNS = 7;
    const int MAX_ROWS = 5;
    const int RADIUS = 14;
    const int PADDING = 14;
    const int ARROW_WIDTH = 28;
    const int ARROW_HEIGHT = 12;
    const int DOCK_GAP = 6;

    const string CSS = """
      .plank-stack-grid, .plank-stack-grid scrolledwindow, .plank-stack-grid viewport,
      .plank-stack-grid flowbox, .plank-stack-grid flowboxchild {
        background: transparent;
        border: none;
        box-shadow: none;
        padding: 0;
      }
      .plank-stack-grid button {
        background: transparent;
        background-image: none;
        border: none;
        border-radius: 10px;
        box-shadow: none;
        padding: 6px 4px;
        color: #ffffff;
        outline: none;
      }
      .plank-stack-grid button:hover,
      .plank-stack-grid button:focus {
        background: alpha(#ffffff, 0.14);
      }
      .plank-stack-grid button:active {
        background: alpha(#ffffff, 0.22);
      }
      .plank-stack-grid .app-name {
        font-size: 12px;
        color: #ffffff;
        text-shadow: 0 1px 2px alpha(#000000, 0.45);
      }
      .plank-stack-grid .footer {
        font-size: 12px;
        color: alpha(#ffffff, 0.75);
        padding: 4px 10px;
      }
      .plank-stack-grid .footer:hover {
        color: #ffffff;
      }
      .plank-stack-grid entry {
        background: alpha(#ffffff, 0.10);
        background-image: none;
        border: 1px solid alpha(#ffffff, 0.14);
        border-radius: 8px;
        box-shadow: none;
        color: #ffffff;
        caret-color: #ffffff;
        font-size: 13px;
        min-height: 28px;
        padding: 0 8px;
      }
      .plank-stack-grid entry:focus {
        border-color: alpha(#0a84ff, 0.85);
        box-shadow: 0 0 0 2px alpha(#0a84ff, 0.35);
      }
      .plank-stack-grid entry image {
        color: alpha(#ffffff, 0.6);
      }
      .plank-stack-grid .no-results {
        font-size: 15px;
        color: alpha(#ffffff, 0.55);
      }
      .plank-stack-grid separator {
        background: alpha(#ffffff, 0.12);
        min-height: 1px;
      }
    """;

    Gtk.PositionType position;
    Gtk.SearchEntry search;
    Gtk.FlowBox flow;
    Gtk.ScrolledWindow scroll;
    Gtk.Label no_results;
    Gee.HashMap<Gtk.Widget, StackGridEntry> cells = new Gee.HashMap<Gtk.Widget, StackGridEntry> ();
    string query = "";
    int arrow_x = 0;
    bool closing = false;
    bool was_active = false;
    ulong active_window_handler = 0;

    /**
     * The footer link was clicked; the grid has already closed.
     */
    public signal void footer_activated ();

    /**
     * Shows a grid of entries for the given dock item, pointing at it.
     *
     * @param controller the item's dock
     * @param item the item to point at
     * @param entries what to show, in order
     * @param title the window's title
     * @param footer_label the text of the link below the grid
     * @param event_time the time of the click that opened it
     */
    public static StackGrid show_for (DockController controller, DockItem item, Gee.List<StackGridEntry> entries,
                                      string title, string footer_label, uint32 event_time) {
      var grid = new StackGrid (controller.position_manager.Position, entries, title, footer_label);

      // Show the contents before measuring: hidden widgets have no size
      grid.get_child ().show_all ();

      int target_x, target_y;
      controller.position_manager.get_hover_position (item, out target_x, out target_y);
      grid.place (target_x, target_y);
      grid.present_with_time (event_time);
      grid.search.grab_focus ();
      return grid;
    }

    StackGrid (Gtk.PositionType position, Gee.List<StackGridEntry> entries, string title, string footer_label) {
      Object (type : Gtk.WindowType.TOPLEVEL, type_hint : Gdk.WindowTypeHint.UTILITY);
      this.position = position;
      decorated = false;
      resizable = false;
      skip_taskbar_hint = true;
      skip_pager_hint = true;
      set_keep_above (true);

      // Before realize: a WM class of its own lets the compositor blur
      // behind the grid without blurring behind the dock.
      set_wmclass ("plank-stack", "Plank-stack");
      set_title (title);
      app_paintable = true;
      var visual = get_screen ().get_rgba_visual ();
      if (visual != null) {
        set_visual (visual);
      }

      var css = new Gtk.CssProvider ();
      try {
        css.load_from_data (CSS);
      } catch (Error e) {
        warning ("Failed to load the grid style: %s", e.message);
      }
      Gtk.StyleContext.add_provider_for_screen (get_screen (), css, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION);
      get_style_context ().add_class ("plank-stack-grid");

      var columns = int.min (MAX_COLUMNS, int.max (3, (int) Math.ceil (Math.sqrt (entries.size * 1.6))));
      columns = int.min (columns, int.max (3, entries.size));
      var rows = int.max (1, (entries.size + columns - 1) / columns);

      flow = new Gtk.FlowBox ();
      flow.homogeneous = true;
      // Keep filtered results at the top instead of centered in the space
      flow.valign = Gtk.Align.START;
      flow.selection_mode = Gtk.SelectionMode.NONE;
      flow.min_children_per_line = columns;
      flow.max_children_per_line = columns;
      flow.row_spacing = 0;
      flow.column_spacing = 0;
      foreach (var entry in entries) {
        var cell = create_cell (entry);
        cells[cell] = entry;
        flow.add (cell);
      }
      flow.set_filter_func (matches_query);

      scroll = new Gtk.ScrolledWindow (null, null);
      scroll.hscrollbar_policy = Gtk.PolicyType.NEVER;
      scroll.vscrollbar_policy = Gtk.PolicyType.AUTOMATIC;
      scroll.overlay_scrolling = true;
      scroll.set_size_request (columns * CELL_WIDTH, int.min (rows, visible_rows ()) * CELL_HEIGHT);
      scroll.add (flow);

      no_results = new Gtk.Label (entries.is_empty ? _ ("Empty") : _ ("No Results"));
      no_results.get_style_context ().add_class ("no-results");
      no_results.no_show_all = true;
      no_results.visible = entries.is_empty;

      var results = new Gtk.Overlay ();
      results.add (scroll);
      results.add_overlay (no_results);

      search = new Gtk.SearchEntry ();
      search.placeholder_text = _ ("Search");
      search.halign = Gtk.Align.CENTER;
      search.width_request = 280;
      search.margin_bottom = 6;
      search.search_changed.connect (on_search_changed);
      search.activate.connect (launch_first_match);

      var footer = new Gtk.Button.with_label (footer_label + "  \u203a");
      footer.relief = Gtk.ReliefStyle.NONE;
      footer.halign = Gtk.Align.CENTER;
      footer.get_style_context ().add_class ("footer");
      footer.clicked.connect (() => {
        close_grid ();
        footer_activated ();
      });

      var box = new Gtk.Box (Gtk.Orientation.VERTICAL, 6);
      box.margin = PADDING;
      if (position == Gtk.PositionType.BOTTOM) {
        box.margin_bottom += ARROW_HEIGHT;
      } else if (position == Gtk.PositionType.TOP) {
        box.margin_top += ARROW_HEIGHT;
      }
      box.pack_start (search, false, false, 0);
      box.pack_start (results, true, true, 0);
      box.pack_start (new Gtk.Separator (Gtk.Orientation.HORIZONTAL), false, false, 0);
      box.pack_start (footer, false, false, 0);
      add (box);

      key_press_event.connect (on_key_press);
      active_window_handler = WindowControl.get_wnck_screen ().active_window_changed.connect (on_active_window_changed);
      size_allocate.connect (update_shape);
    }

    /**
     * How many rows fit on the screen above (or below) the dock.
     */
    int visible_rows () {
      var display = get_display ();
      var monitor = display.get_primary_monitor () ?? display.get_monitor (0);
      var screen_height = monitor.get_geometry ().height;
      var room = screen_height / 2 + screen_height / 4;
      // Leave room for the search field and the footer
      return int.max (1, int.min (MAX_ROWS, (room - 2 * PADDING - ARROW_HEIGHT - 88) / CELL_HEIGHT));
    }

    Gtk.Widget create_cell (StackGridEntry entry) {
      var image = new Gtk.Image.from_pixbuf (DrawingService.load_icon (entry.icon, ICON_SIZE, ICON_SIZE));

      var label = new Gtk.Label (entry.name);
      label.get_style_context ().add_class ("app-name");
      label.ellipsize = Pango.EllipsizeMode.END;
      label.max_width_chars = 1;
      label.width_request = CELL_WIDTH - 16;
      label.justify = Gtk.Justification.CENTER;

      var content = new Gtk.Box (Gtk.Orientation.VERTICAL, 4);
      content.pack_start (image, false, false, 0);
      content.pack_start (label, false, false, 0);

      var button = new Gtk.Button ();
      button.relief = Gtk.ReliefStyle.NONE;
      button.tooltip_text = entry.name;
      button.set_size_request (CELL_WIDTH - 8, CELL_HEIGHT - 8);
      button.halign = Gtk.Align.CENTER;
      button.valign = Gtk.Align.CENTER;
      button.add (content);

      button.clicked.connect (() => launch (entry));

      return button;
    }

    void launch (StackGridEntry entry) {
      close_grid ();
      entry.activated ();
    }

    bool matches_query (Gtk.FlowBoxChild child) {
      if (query == "") {
        return true;
      }
      var entry = cells[child.get_child ()];
      return entry != null && entry.name.casefold ().contains (query);
    }

    void on_search_changed () {
      query = search.text.strip ().casefold ();
      flow.invalidate_filter ();
      scroll.vadjustment.value = 0;

      var any = first_match () != null;
      no_results.visible = !any;
    }

    StackGridEntry? first_match () {
      foreach (var child in flow.get_children ()) {
        var flow_child = (Gtk.FlowBoxChild) child;
        if (matches_query (flow_child)) {
          return cells[flow_child.get_child ()];
        }
      }
      return null;
    }

    void launch_first_match () {
      var entry = first_match ();
      if (entry != null) {
        launch (entry);
      }
    }

    /**
     * Positions the window so its arrow points at (target_x, target_y), the
     * point above the item where Plank shows its hover tooltip, keeping the
     * whole panel on the item's monitor.
     */
    void place (int target_x, int target_y) {
      Gtk.Requisition size;
      get_child ().get_preferred_size (null, out size);
      var width = size.width;
      var height = size.height;

      var monitor = get_display ().get_monitor_at_point (target_x, target_y).get_geometry ();

      int x, y;
      switch (position) {
      default:
      case Gtk.PositionType.BOTTOM:
        x = target_x - width / 2;
        y = target_y - height - DOCK_GAP;
        break;
      case Gtk.PositionType.TOP:
        x = target_x - width / 2;
        y = target_y + DOCK_GAP;
        break;
      case Gtk.PositionType.LEFT:
        x = target_x + DOCK_GAP;
        y = target_y - height / 2;
        break;
      case Gtk.PositionType.RIGHT:
        x = target_x - width - DOCK_GAP;
        y = target_y - height / 2;
        break;
      }

      x = x.clamp (monitor.x + DOCK_GAP, monitor.x + monitor.width - width - DOCK_GAP);
      y = y.clamp (monitor.y + DOCK_GAP, monitor.y + monitor.height - height - DOCK_GAP);
      arrow_x = (target_x - x).clamp (RADIUS + ARROW_WIDTH / 2, width - RADIUS - ARROW_WIDTH / 2);

      set_default_size (width, height);
      move (x, y);
    }

    void on_active_window_changed () {
      unowned Wnck.Window? active = WindowControl.get_wnck_screen ().get_active_window ();
      if (active != null && active.get_class_instance_name () == "plank-stack") {
        was_active = true;
        return;
      }
      // Only once the grid has been active, so its own opening doesn't count
      if (was_active) {
        // Close once the signal is done rather than inside its handler
        Idle.add (() => { close_grid (); return false; });
      }
    }

    public signal void closed ();

    public void close_grid () {
      if (closing) {
        return;
      }
      closing = true;

      if (active_window_handler > 0) {
        WindowControl.get_wnck_screen ().disconnect (active_window_handler);
        active_window_handler = 0;
      }
      closed ();
      destroy ();
    }

    bool on_key_press (Gdk.EventKey event) {
      if (event.keyval == Gdk.Key.Escape) {
        if (search.text != "") {
          search.text = "";
        } else {
          close_grid ();
        }
        return true;
      }
      return false;
    }

    /**
     * The panel with its arrow, in window coordinates.
     */
    void panel_path (Cairo.Context cr, double inset) {
      double width = get_allocated_width ();
      double height = get_allocated_height ();

      double top = inset;
      double bottom = height - inset;
      if (position == Gtk.PositionType.BOTTOM) {
        bottom -= ARROW_HEIGHT;
      } else if (position == Gtk.PositionType.TOP) {
        top += ARROW_HEIGHT;
      }
      double left = inset;
      double right = width - inset;
      double r = RADIUS - inset;
      double half = ARROW_WIDTH / 2.0;

      cr.new_path ();
      cr.arc (left + r, top + r, r, Math.PI, 3 * Math.PI_2);
      if (position == Gtk.PositionType.TOP) {
        cr.line_to (arrow_x - half, top);
        cr.curve_to (arrow_x - half / 3, top, arrow_x - 3, top - ARROW_HEIGHT + inset, arrow_x, top - ARROW_HEIGHT + inset);
        cr.curve_to (arrow_x + 3, top - ARROW_HEIGHT + inset, arrow_x + half / 3, top, arrow_x + half, top);
      }
      cr.arc (right - r, top + r, r, 3 * Math.PI_2, 2 * Math.PI);
      cr.arc (right - r, bottom - r, r, 0, Math.PI_2);
      if (position == Gtk.PositionType.BOTTOM) {
        cr.line_to (arrow_x + half, bottom);
        cr.curve_to (arrow_x + half / 3, bottom, arrow_x + 3, bottom + ARROW_HEIGHT - inset, arrow_x, bottom + ARROW_HEIGHT - inset);
        cr.curve_to (arrow_x - 3, bottom + ARROW_HEIGHT - inset, arrow_x - half / 3, bottom, arrow_x - half, bottom);
      }
      cr.arc (left + r, bottom - r, r, Math.PI_2, Math.PI);
      cr.close_path ();
    }

    /**
     * Clips the window (and so the compositor's blur and shadow) to the
     * panel and its arrow.
     */
    void update_shape () {
      var width = get_allocated_width ();
      var height = get_allocated_height ();
      if (width <= 0 || height <= 0 || get_window () == null) {
        return;
      }

      var mask = new Cairo.ImageSurface (Cairo.Format.A1, width, height);
      var cr = new Cairo.Context (mask);
      cr.set_antialias (Cairo.Antialias.NONE);
      panel_path (cr, 0);
      cr.fill ();

      get_window ().shape_combine_region (Gdk.cairo_region_create_from_surface (mask), 0, 0);
    }

    public override bool draw (Cairo.Context cr) {
      cr.save ();
      cr.set_operator (Cairo.Operator.SOURCE);
      cr.set_source_rgba (0, 0, 0, 0);
      cr.paint ();
      cr.set_operator (Cairo.Operator.OVER);

      // Dark vibrancy: a translucent fill over the compositor's blur, a
      // hairline dark edge and a faint light inner edge, like macOS.
      panel_path (cr, 0.5);
      cr.set_source_rgba (0.12, 0.12, 0.13, 0.62);
      cr.fill_preserve ();
      cr.set_line_width (1);
      cr.set_source_rgba (0, 0, 0, 0.55);
      cr.stroke ();

      panel_path (cr, 1.5);
      cr.set_source_rgba (1, 1, 1, 0.13);
      cr.stroke ();
      cr.restore ();

      return base.draw (cr);
    }
  }
}
