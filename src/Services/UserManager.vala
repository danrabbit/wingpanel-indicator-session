/*
 * Copyright (c) 2011-2017 elementary LLC. (http://launchpad.net/wingpanel)
 *
 * This program is free software; you can redistribute it and/or
 * modify it under the terms of the GNU General Public
 * License as published by the Free Software Foundation; either
 * version 2 of the License, or (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * General Public License for more details.
 *
 * You should have received a copy of the GNU General Public
 * License along with this program; if not, write to the
 * Free Software Foundation, Inc., 51 Franklin Street, Fifth Floor,
 * Boston, MA 02110-1301 USA
 */

public enum UserState {
    ACTIVE,
    ONLINE,
    OFFLINE;

    public static UserState to_enum (string state) {
        switch (state) {
            case "active":
                return UserState.ACTIVE;
            case "online":
                return UserState.ONLINE;
        }

        return UserState.OFFLINE;
    }
}

public class Session.Services.UserManager : Object {
    public signal void close ();

    public bool has_guest { get; private set; default = false; }
    public Session.Widgets.UserListBox user_grid { get; private set; }
    public Wingpanel.Widgets.Separator users_separator { get; construct; }

    private const uint GUEST_USER_UID = 999;
    private const uint NOBODY_USER_UID = 65534;
    private const uint RESERVED_UID_RANGE_END = 1000;

    private const string DM_DBUS_ID = "org.freedesktop.DisplayManager";
    private const string LOGIN_IFACE = "org.freedesktop.login1";
    private const string LOGIN_PATH = "/org/freedesktop/login1";

    private Act.UserManager manager;
    private Gee.HashMap<uint, Widgets.Userbox>? users;
    private SeatInterface? dm_proxy = null;

    private static SystemInterface? login_proxy;

    static construct {
        try {
            login_proxy = Bus.get_proxy_sync (BusType.SYSTEM, LOGIN_IFACE, LOGIN_PATH, DBusProxyFlags.NONE);
        } catch (IOError e) {
            stderr.printf ("UserManager error: %s\n", e.message);
        }
    }

    public static UserState get_user_state (uint32 uuid) {
        if (login_proxy == null) {
            return UserState.OFFLINE;
        }

        try {
            UserInfo[] users = login_proxy.list_users ();
            if (users == null) {
                return UserState.OFFLINE;
            }

            foreach (UserInfo user in users) {
                if (user.uid == uuid) {
                    if (user.user_object == null) {
                        return UserState.OFFLINE;
                    }
                    UserInterface? user_interface = Bus.get_proxy_sync (BusType.SYSTEM, LOGIN_IFACE, user.user_object, DBusProxyFlags.NONE);
                    if (user_interface == null) {
                        return UserState.OFFLINE;
                    }
                    return UserState.to_enum (user_interface.state);
                }
            }

        } catch (GLib.Error e) {
            stderr.printf ("Error: %s\n", e.message);
        }

        return UserState.OFFLINE;
    }

    public static UserState get_guest_state () {
        if (login_proxy == null) {
            return UserState.OFFLINE;
        }

        try {
            UserInfo[] users = login_proxy.list_users ();
            foreach (UserInfo user in users) {
                var state = get_user_state (user.uid);
                if (user.user_name.has_prefix ("guest-")
                    && state == UserState.ACTIVE) {
                    return UserState.ACTIVE;
                }
            }
        } catch (GLib.Error e) {
            stderr.printf ("Error: %s\n", e.message);
        }

        return UserState.OFFLINE;
    }

    public UserManager (Wingpanel.Widgets.Separator users_separator) {
        Object (users_separator: users_separator);
    }

    construct {
        users_separator.no_show_all = true;
        users_separator.visible = false;

        user_grid = new Session.Widgets.UserListBox ();
        user_grid.close.connect (() => close ());

        manager = Act.UserManager.get_default ();
        init_users ();

        manager.user_added.connect (add_user);
        manager.user_removed.connect (remove_user);
        manager.user_is_logged_in_changed.connect (update_user);

        manager.notify["is-loaded"].connect (() => {
            if (manager.is_loaded) {
                init_users ();
            }
        });

        var seat_path = Environment.get_variable ("XDG_SEAT_PATH");

        if (seat_path != null) {
            try {
                dm_proxy = Bus.get_proxy_sync (BusType.SYSTEM, DM_DBUS_ID, seat_path, DBusProxyFlags.NONE);
                has_guest = dm_proxy.has_guest_account;
            } catch (IOError e) {
                stderr.printf ("UserManager error: %s\n", e.message);
            }
        }
    }

    private void init_users () {
        if (!manager.is_loaded) {
            return;
        }

        foreach (Act.User user in manager.list_users ()) {
            add_user (user);
        }
    }

    private void add_user (Act.User? user) {
        if (users == null) {
            users = new Gee.HashMap<uint, Widgets.Userbox> ();
        }

        // Don't add any of the system reserved users
        var uid = user.get_uid ();
        if (uid < RESERVED_UID_RANGE_END || uid == NOBODY_USER_UID || users.has_key (uid)) {
            return;
        }

        users[uid] = new Session.Widgets.Userbox (user);
        user_grid.add (users[uid]);

        users_separator.visible = true;
    }

    private void remove_user (Act.User user) {
        var uid = user.get_uid ();
        var userbox = users[uid];
        if (userbox == null) {
            return;
        }

        users.unset (uid);
        user_grid.remove (userbox);
    }

    private void update_user (Act.User user) {
        var userbox = users[user.get_uid ()];
        if (userbox == null) {
            return;
        }

        userbox.update_state ();
    }

    public void update_all () {

        foreach (var userbox in users) {
            userbox.update_state ();
        }
    }

    public void add_guest (bool logged_in) {
        if (users == null) {
            users = new Gee.HashMap<uint, Widgets.Userbox> ();
        }

        if (users[GUEST_USER_UID] != null) {
            return;
        }

        users[GUEST_USER_UID] = new Session.Widgets.Userbox.from_data (_("Guest"), logged_in, true);
        users[GUEST_USER_UID].show ();

        user_grid.add_guest (users[GUEST_USER_UID]);

        users_separator.visible = true;
    }
}
