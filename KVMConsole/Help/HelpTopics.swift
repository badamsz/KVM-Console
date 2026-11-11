import Foundation

// The help text. See `HelpBlock` for the syntax. Link to another topic with
// [Its Title](help:topic-id). Keep this in step with the README when features change.

extension HelpTopic {
    static let all: [HelpTopic] = [
        gettingStarted, addingDevices, findingDevices, console, keyboardAndMouse,
        virtualMedia, power, pikvmSwitch, nanoKVM, openterface, configuringPiKVM,
        updatingPiKVM, certificates, menuBar, shortcuts, troubleshooting,
    ]

    static let gettingStarted = HelpTopic(
        "getting-started", title: "Getting Started", symbol: "sparkles",
        keywords: ["overview", "introduction", "welcome", "supported devices"],
        body: """
        KVM Console controls computers through a KVM-over-IP device: you see the computer's screen in a window on your Mac, type and use the mouse on it, mount ISO images, and switch it on and off, even when it's sitting in the BIOS or has no operating system yet.

        ## Supported devices
        - **PiKVM** V3, V4 Mini, V4 Plus and DIY builds, including a **PiKVM Switch** (or two chained Switches) with up to 8 machines. See [PiKVM Switch](help:pikvm-switch).
        - **Sipeed NanoKVM** (Cube, Lite, PCIe), **NanoKVM Pro** and **NanoKVM Go**. See [Sipeed NanoKVM](help:nanokvm).
        - **Openterface** USB KVMs plugged straight into this Mac. See [Openterface](help:openterface).

        ## First steps
        1. Choose **File > Find Devices on Network…** (⇧⌘F) to look for KVMs, or **File > Add Device…** (⇧⌘N) to type in an address. See [Adding Devices](help:adding-devices).
        2. Pick a machine in the sidebar. Its page shows whether it's connected, a picture of its screen, power controls and the virtual drive.
        3. Choose **Open Console** (⌘↩) to control it. See [Using the Console](help:console).

        ## Devices and machines
        A **device** is the KVM itself (a PiKVM, NanoKVM or Openterface). A **machine** is a computer it controls. Most devices control one machine, which takes the device's name. A PiKVM with a Switch lists one machine per Switch port under the device in the sidebar.

        > Settings such as the mouse mode are saved per machine, so every Switch port can have its own.
        """)

    static let addingDevices = HelpTopic(
        "adding-devices", title: "Adding Devices", symbol: "plus.circle",
        keywords: ["new device", "edit", "remove", "delete", "address", "password", "login", "tailscale", "2fa", "totp", "two-factor", "model"],
        body: """
        Choose **File > Add Device…** (⇧⌘N) or the + button above the sidebar. To have the details filled in for you, use [Finding Devices](help:finding-devices) instead and press **Add…** next to a find.

        ## The device editor
        - **Name**: what the sidebar shows, such as "Rack KVM".
        - **Model**: pick the exact model. It decides how the app talks to the device; a NanoKVM and a NanoKVM Pro run different software, so the wrong one won't connect. Choose *Other PiKVM / DIY* for a home-built PiKVM.
        - **LAN address**: an IP address or name on your network, such as `192.168.1.50` or `pikvm.local`.
        - **Tailscale address**: the device's tailnet name, such as `pikvm.tailnet-name.ts.net`. Either address can be left empty.
        - **Username and Password**: the login for the device's web page. The password is kept in your Keychain. PiKVM uses `admin` by default; a NanoKVM uses admin / admin until you change it.

        The LAN address is tried first and Tailscale second, so the same device works at home and away. Press **Test Connection** to check the details before saving; it says which address answered and the software version.

        > If two-factor authentication is on for a PiKVM, add the current six-digit code to the end of the password each time you connect.

        ## Changing or removing a device
        Right-click the device in the sidebar and choose **Edit…**, **Reconnect** or **Remove**, or use **Edit Device** in a machine's toolbar. Removing a device also deletes its saved passwords from the Keychain.

        Changing a device's addresses or model makes the app forget the certificate it saved for it. See [Certificates](help:certificates).
        """)

    static let findingDevices = HelpTopic(
        "finding-devices", title: "Finding Devices on the Network", symbol: "antenna.radiowaves.left.and.right",
        keywords: ["discover", "discovery", "scan", "bonjour", "avahi", "tailscale", "token", "api key", "local network"],
        body: """
        Choose **File > Find Devices on Network…** (⇧⌘F), or the antenna button above the sidebar. The window lists every KVM it finds; press **Add…** to open the device editor with the name, model and addresses filled in. Devices you already have are marked Added. Nothing is sent to a network device except a request for its web page; no passwords are tried.

        ## Bonjour
        Runs while the window is open. A PiKVM only announces itself once Avahi is on: add `ENABLE_AVAHI=1` to `/boot/pikvm.txt`, or run `rw`, then `systemctl enable --now avahi-daemon`. NanoKVMs answer under their host name.

        ## Network Scan
        Checks every address on the Mac's local networks (the /24 around the Mac on bigger networks) for a web server on ports 443 and 80, and recognises PiKVM and NanoKVM by their login pages.

        > The first time, macOS asks whether KVM Console may find devices on your local network. Allow it and scan again. If you said no, turn it on in **System Settings > Privacy & Security > Local Network**.

        ## Tailscale
        The app is sandboxed and can't ask the Tailscale app for your machines, so it uses the Tailscale API instead:
        1. In the Tailscale admin console, open **Settings > Keys** and generate an **API access token**.
        2. Paste it into the Tailscale section of Find Devices and press **Save**. It is kept in your Keychain.
        3. The app checks your tailnet's online Linux machines the same way as the network scan.

        A tailnet machine with the same name as something found on the LAN becomes one entry with both addresses. **Forget API Token** removes the token.

        ## Plugged into this Mac
        Openterface units connected by USB are listed here. See [Openterface](help:openterface).

        > A NanoKVM found over plain HTTP is guessed to be a classic NanoKVM, and one over HTTPS a NanoKVM Pro. Check the model in the editor before adding it.
        """)

    static let console = HelpTopic(
        "console", title: "Using the Console", symbol: "display",
        keywords: ["remote control", "full screen", "fullscreen", "video", "h.264", "webrtc", "mjpeg", "audio", "sound", "microphone", "camera", "webcam", "paste", "clipboard", "typing", "send keys", "ctrl+alt+del"],
        body: """
        Select a machine and choose **File > Open Console** (⌘↩), double-click the screen picture on its page, or use **Open Console** in the menu bar item. Each machine gets its own console window; opening it again brings that window forward.

        ## Full screen
        Press ⌃⌘F or the full-screen button in the toolbar. In full screen the toolbar hides so the picture fills the display; **View > Hide Toolbar in Full Screen** (⌃⌘T) turns that off. Move the pointer to the top edge to reach the menu bar.

        ## The toolbar
        - **Mouse**: absolute or relative. See [Keyboard and Mouse](help:keyboard-mouse).
        - **Power lights and Power menu**: shown when the machine has ATX wired up. See [Power Control](help:power).
        - **Video**: H.264 (WebRTC) is the default on a PiKVM and carries sound. MJPEG is the fallback, used automatically when H.264 can't connect; the menu says why.
        - **Audio**: mute and volume, shown when the PiKVM sends sound.
        - **Microphone and Camera**: send this Mac's microphone or camera to the remote machine. See below.
        - **Virtual Media** (the disc): mount ISO images. See [Virtual Media](help:virtual-media).
        - **Send Keys**: key combinations macOS would otherwise keep, such as Ctrl+Alt+Del, Alt+Tab, Alt+F4, the Windows key, Ctrl+Alt+F1 and Print Screen, plus paste and typing speed.

        ## Paste as typing
        **Console > Paste Clipboard as Typing** (⌥⌘V) types the text on the Mac's clipboard on the remote machine, key by key, so it works in a BIOS or installer too. Choose a slower **Typing Speed** in the Send Keys menu for BIOS screens and slow machines. Long text, or text with line breaks, asks first, and a progress bar with **Cancel** appears while it types.

        > Paste types with the PiKVM's keymap (US unless you changed it), so the remote machine's keyboard layout must match. NanoKVM and Openterface always type with a US layout.

        ## Microphone and camera passthrough
        On a PiKVM set up for it, the **Microphone and Camera** menu sends this Mac's microphone and camera to the remote machine, which sees a USB microphone and webcam. It needs H.264 video and the USB microphone or webcam turned on in the PiKVM's settings (see [Configuring a PiKVM](help:configure-pikvm)). Both start off in every new console, and switching either one reconnects the video briefly. The camera only starts once an app on the remote machine opens the webcam.

        ## No video signal
        "No video signal" means the PiKVM sees nothing on its HDMI input: the machine may be off, asleep, or on another Switch port. Keyboard and mouse still work, so pressing a key often wakes it. **Console > Reconnect Video** (⌃⌘R) starts the video again.
        """)

    static let keyboardAndMouse = HelpTopic(
        "keyboard-mouse", title: "Keyboard and Mouse", symbol: "computermouse",
        keywords: ["absolute", "relative", "mouse mode", "capture", "release", "cursor", "pointer", "keyboard layout", "command key", "windows key", "super"],
        body: """
        ## Mouse modes
        - **Absolute**: the remote pointer goes exactly where your cursor is. Best for desktops and most operating systems.
        - **Relative**: the remote machine gets movements, like a real mouse. Some BIOS screens, installers and games only understand this. Click the video to capture your cursor, and press **Control+Option** to release it.

        Switch modes with the **Mouse** picker in the console toolbar, on the machine's page, or with **Console > Switch Mouse Mode** (⌃⌘M). The choice is saved for each machine, and for each port of a PiKVM Switch.

        > On a PiKVM, relative mode needs kvmd's alternate (relative) mouse turned on in its USB settings. Until it is, the machine's page says so and only absolute mode is offered. See [Configuring a PiKVM](help:configure-pikvm).

        ## Keyboard
        While a console window is in front, keys go to the remote machine, including Command shortcuts: ⌘ is sent as the Windows (Super) key. Keys are sent by their position, so the remote machine's own keyboard layout decides which character appears.

        macOS keeps a few combinations for itself, such as ⌘Tab and ⌘Space. Use the **Send Keys** menu in the toolbar to send Ctrl+Alt+Del and similar combinations.

        Shortcuts that use **Control+Command** always stay on the Mac. That is why the console's own shortcuts all use it. See [Keyboard Shortcuts](help:shortcuts).
        """)

    static let virtualMedia = HelpTopic(
        "virtual-media", title: "Virtual Media (ISO Images)", symbol: "opticaldisc",
        keywords: ["iso", "img", "disk image", "mount", "msd", "mass storage", "upload", "cd", "dvd", "flash drive", "usb drive", "eject", "install os", "download url"],
        body: """
        Each PiKVM and NanoKVM has a virtual USB drive. Put an ISO or disk image on it and the remote machine sees a CD/DVD drive or a USB flash drive, ready to boot an installer from.

        Open it with **Manage Images…** on the machine's page, the disc button in the console toolbar, or **Console > Virtual Media…** (⌃⌘I).

        ## Mounting an image
        1. Press **Upload Image…** and pick an ISO or disk image on your Mac. A progress bar shows the upload; **Cancel** stops it and removes the partial file.
        2. Select the image in the list.
        3. Choose **CD/DVD** or **Flash drive**. A flash drive can be made writable with *Let the remote machine write to the image*; a CD/DVD is always read-only.
        4. Press **Connect**. Restart the remote machine and pick the USB or CD drive in its boot menu if it doesn't boot from it by itself.
        5. Press **Eject** when you're done.

        > Uploading, deleting and switching images all need the drive ejected first. That's a PiKVM rule.

        ## Behind a PiKVM Switch
        There's one virtual drive per PiKVM, and it goes to whichever Switch port is active. Switch to the machine's port before connecting an image.

        ## On a NanoKVM
        - **Download from URL…** has the NanoKVM download an image from the internet itself. It keeps going if you close the window.
        - Uploading from the Mac needs firmware 2.5.3 or newer on a classic NanoKVM. Older ones can download from a URL, or you can copy an image to `/data` with `scp`.
        - On a classic NanoKVM, Eject goes back to sharing its data partition, and images are always read-only. The Pro and Go can make a flash drive writable.
        """)

    static let power = HelpTopic(
        "power", title: "Power Control (ATX)", symbol: "bolt",
        keywords: ["atx", "power on", "shut down", "shutdown", "reset", "force off", "reboot", "led", "hdd light", "wake"],
        body: """
        When a machine's power and reset buttons are wired to the KVM (ATX), the app shows its power and disk-activity lights and lets you press the buttons remotely: on the machine's page, in the console toolbar's **Power** menu, and in the menu bar item.

        - **Power On** presses the power button when the machine is off.
        - **Shut Down** presses the power button briefly, which asks the operating system to shut down.
        - **Reset** presses the reset button. In the console it asks first.
        - **Force Off** holds the power button until the machine turns off, like holding it for several seconds. It always asks first, because unsaved work is lost.

        Machines without ATX don't show these controls; the machine's page says "ATX control isn't available for this machine." On a PiKVM, ATX can be turned on or off in [Configuring a PiKVM](help:configure-pikvm).

        Machines behind a PiKVM Switch use the Switch's own power connections, so each port has its own lights and buttons. A NanoKVM needs its ATX board.
        """)

    static let pikvmSwitch = HelpTopic(
        "pikvm-switch", title: "PiKVM Switch", symbol: "rectangle.connected.to.line.below",
        keywords: ["switch", "ports", "chained", "multiple machines", "beacon", "blink", "active port", "v4 plus"],
        body: """
        A PiKVM with a PiKVM Switch (or two chained Switches) controls several machines. The app reads the ports from the PiKVM and lists each one as a machine under the device in the sidebar. Port names and per-port settings such as the mouse mode are kept.

        ## Switching ports
        The PiKVM sees one port at a time, the **active** port, marked with a check in the sidebar.
        - Double-click a machine in the sidebar, or select it and press Return, to make its port active. Its right-click menu has **Switch to This Port** too, as does its page.
        - Double-clicking a machine that's already on screen opens its console.

        ## What follows the active port
        - The console video, keyboard and mouse.
        - The screen picture on a machine's page. Other ports keep their last picture and can't be refreshed until they're active.
        - The virtual drive. Switch first, then connect an image.

        Power control works on every port at any time, because the Switch has its own ATX connections for each.

        ## Finding a port on the hardware
        Turn on **Blink this port's light on the Switch** on a machine's page to find its port and cables on the Switch.
        """)

    static let nanoKVM = HelpTopic(
        "nanokvm", title: "Sipeed NanoKVM, Pro and Go", symbol: "cpu",
        keywords: ["sipeed", "nanokvm", "cube", "lite", "pcie", "pro", "go", "http", "https"],
        body: """
        Add a NanoKVM with **Model** set to *Sipeed NanoKVM* (Cube, Lite and PCIe), *Sipeed NanoKVM Pro* or *Sipeed NanoKVM Go*, and the login you use on its web page (admin / admin until you change it). The model matters: the NanoKVM and the NanoKVM Pro run different software. The Go runs the Pro's.

        ## What works
        - The console with MJPEG video, keyboard, and absolute or relative mouse. Keyboard input needs NanoKVM 2.3.2 or newer.
        - Paste as typing, always with a US layout.
        - Power control on models with the ATX board.
        - Virtual media, including **Download from URL…**. See [Virtual Media](help:virtual-media).
        - The screen picture on the machine's page.

        Not yet: H.264 video, sound, and microphone or camera passthrough.

        ## HTTP and HTTPS
        A classic NanoKVM uses plain HTTP unless HTTPS is turned on in its settings; the Pro and Go use HTTPS with a self-signed certificate. The app tries HTTPS first and falls back to HTTP, and once it has seen a certificate for the device it only uses HTTPS. To force one or the other, write it into the address, such as `http://192.168.1.60`.

        > macOS only allows plain HTTP to IP addresses, `.local` names, bare host names and Tailscale `*.ts.net` names. Use HTTPS for any other name.
        """)

    static let openterface = HelpTopic(
        "openterface", title: "Openterface USB KVMs", symbol: "cable.connector",
        keywords: ["openterface", "mini-kvm", "kvm-go", "usb", "serial", "ch9329", "ch32v208", "capture card", "plugged in", "microsd", "sd card"],
        body: """
        An Openterface Mini-KVM or KVM-GO (USB 2.0 or USB 3.0) connects the remote machine straight to this Mac by USB, with no network. Connect its host cable to the Mac, and its target cable and HDMI to the machine you want to control.

        ## Adding one
        Plug it in and it appears in the sidebar as *Openterface* (then *Openterface 2*, and so on). Choose **Rename…** from its menu in the sidebar to give it a name. It leaves the sidebar when you unplug it and comes back with the same name and settings when you plug it in again, even after quitting the app.

        - A unit is recognised by the USB port it's in. If it reports a USB serial number, it's recognised in any port. Without one, a single unit moved to another port is still recognised, but two units that swap ports swap names.
        - **Remove** takes a plugged-in unit off the list until it's unplugged and plugged in again.
        - **KVM Console > Settings…** can stop units being added when they're plugged in, or keep unplugged ones in the sidebar. With adding turned off, add one from **Find Devices > Plugged into this Mac**, or with **Add Device…** and the *Openterface (USB)* model.

        ## USB Devices window
        **File > USB Devices…** (⇧⌘U) lists the Openterface units this Mac can see, with their video, keyboard and mouse controller and audio, and an **Add…** button for each. Below them it lists every camera, serial port and audio input, so you can tell a unit that isn't recognised from one that isn't connected. It also shows camera and microphone access, and **Copy Details** copies the whole list as text for a bug report.

        - Video and sound arrive as a USB camera and microphone, so macOS asks for camera and microphone access the first time. If you said no, turn KVM Console on in **System Settings > Privacy & Security > Camera** and **Microphone**.
        - The keyboard and mouse go through the unit's serial controller, with absolute or relative mouse like the other devices.
        - Paste as typing uses a US keyboard layout.
        - On a KVM-GO, the **MicroSD Card** button in the console's toolbar connects the unit's microSD card to the machine or to this Mac. It also follows the unit's own switch button. Eject the card on the side that has it before switching.

        > Quit the Openterface app first: only one app at a time can use the unit's keyboard and mouse controller.
        """)

    static let configuringPiKVM = HelpTopic(
        "configure-pikvm", title: "Configuring a PiKVM", symbol: "gearshape",
        keywords: ["settings", "override.yaml", "kvmd", "otg", "usb audio", "webcam", "jiggler", "vnc", "ipmi", "bitrate", "frame rate", "backup", "restore", "root password", "alternate mouse"],
        body: """
        **Configure PiKVM…** (the gear in a machine's toolbar, or right-click the device) shows and changes the PiKVM's settings in `/etc/kvmd/override.yaml`. It works through the PiKVM's web terminal as root, so it needs no SSH, but it asks for the root password. You can save that password in the Keychain; the updater uses the same one.

        ## Settings
        Switches for the common options:
        - USB devices: audio, webcam, Ethernet, serial and extra drives. These need a reboot.
        - Video quality, frame rate and H.264 bitrate.
        - Keyboard and mouse, including the mouse jiggler.
        - Turning ATX and the virtual drive on or off, and the VNC and IPMI services.

        Options this PiKVM's software doesn't know are hidden. **Apply…** lists the changes before saving them; **Edit in override.yaml** writes them into the file instead so you can check them first.

        ## override.yaml
        The file itself, in a plain-text editor. **Check** asks kvmd whether it accepts the file without saving anything. **Save and Restart…** saves it.

        ## Backups
        Every save keeps the previous file (the last 20). Pick a backup to see it, open it in the editor, or restore it.

        ## How a save is made safe
        1. kvmd checks the new file together with the PiKVM's other configuration.
        2. The read-only filesystem is made writable only while the file is replaced.
        3. Only the services that use the changed sections restart.
        4. If a restarted service doesn't stay up, the previous file is put back and the service log is shown.

        Changes to USB devices (`otg:`) only take effect after a reboot; the app offers **Reboot Now**.
        """)

    static let updatingPiKVM = HelpTopic(
        "update-pikvm", title: "Updating PiKVM OS", symbol: "arrow.down.circle",
        keywords: ["update", "upgrade", "pikvm-update", "pacman", "root password", "webterm"],
        body: """
        **Update PiKVM OS…** (in a machine's toolbar, or right-click the device) runs `pikvm-update` on the PiKVM through its web terminal and shows the log as it runs. It asks for the PiKVM's root password, which you can save in the Keychain.

        - The update keeps running on the PiKVM if the connection drops or you press **Hide** to close the window.
        - The PiKVM restarts by itself when updates were installed.
        - It needs the PiKVM's web terminal (`kvmd-webterm`), which PiKVM OS turns on by default.
        """)

    static let certificates = HelpTopic(
        "certificates", title: "Certificates and Custom CAs", symbol: "lock.shield",
        keywords: ["tls", "ssl", "https", "self-signed", "pinning", "pinned", "fingerprint", "certificate authority", "ca", "root ca", "step-ca", "acme", "keychain access", "always trust", "untrusted", "renewal", "forget certificate"],
        body: """
        KVM Console always connects to PiKVMs and NanoKVM Pros over HTTPS and checks the certificate. The machine's page shows which kind of certificate the device uses.

        ## Self-signed certificates
        A PiKVM comes with a self-signed certificate that no Mac trusts. The first time the app connects, it saves that certificate's fingerprint, and from then on it only accepts that exact certificate. If a different one turns up, the connection is refused with "presented a different certificate from the one saved for this device".

        If you replaced the certificate yourself, or reinstalled the PiKVM, edit the device, press **Forget Certificate** and save. The next connection saves the new one.

        ## Certificates from your own certificate authority
        If the device's certificate comes from a certificate authority this Mac trusts, such as an internal step-ca that the PiKVM renews from with ACME, the app notices on the first connection. From then on it accepts any certificate that CA issues for the device, so automatic renewals keep working, and it refuses certificates the Mac doesn't trust.

        To set that up:
        1. Get your CA's root certificate (for step-ca, `step ca root root_ca.crt`).
        2. Double-click it to add it to Keychain Access, in the login or System keychain.
        3. Double-click the certificate in Keychain Access, open **Trust**, and set **When using this certificate** to **Always Trust**. Close the window and enter your password.
        4. Install the CA-issued certificate on the PiKVM, then connect. If the app had already saved the old self-signed certificate, edit the device and press **Forget Certificate** first.

        A certificate issued for one of the device's names (say its LAN name) is accepted when connecting through its other address (say Tailscale), so one certificate covers both.

        > If a CA-trusted device is refused with "presented a certificate this Mac doesn't trust", its certificate may have expired without renewing, or the CA's root may no longer be trusted in Keychain Access.

        ## When the app forgets a certificate
        Changing a device's addresses or model, or pressing **Forget Certificate**, clears what the app knows. The next successful connection learns it again.
        """)

    static let menuBar = HelpTopic(
        "menu-bar", title: "Menu Bar and Previews", symbol: "menubar.rectangle",
        keywords: ["menu bar", "status item", "preview", "thumbnail", "snapshot", "screenshot", "refresh", "settings", "preferences"],
        body: """
        ## Menu bar item
        The KVM Console item in the menu bar lists every machine with its power state. Each one has **Open Console**, **Show in Main Window** and, when ATX is wired up, the power actions. Turn the item off in **KVM Console > Settings…** (⌘,).

        ## Screen pictures
        A machine's page shows a still picture of its screen. **Refresh** takes a new one, and double-clicking it opens the console. A PiKVM only runs its video while someone is watching, so a refresh can take a few seconds while the video starts. Behind a PiKVM Switch, only the active port can be refreshed.

        ## Settings
        **KVM Console > Settings…** (⌘,) has two options: showing the menu bar item, and hiding the console toolbar in full screen.
        """)

    static let shortcuts = HelpTopic(
        "shortcuts", title: "Keyboard Shortcuts", symbol: "command",
        keywords: ["hotkeys", "keys", "shortcut", "keyboard shortcuts"],
        body: """
        ## Main window
        = ⇧⌘N | Add a device
        = ⇧⌘F | Find devices on the network
        = ⇧⌘U | Show USB devices
        = ⌘↩ | Open the console for the selected machine
        = Return | Make the selected machine's Switch port active
        = ⌘, | Settings
        = ⌘? | KVM Console Help

        ## Console window
        These use Control+Command, which the console keeps for the Mac instead of sending to the remote machine.
        = ⌃⌘⌫ | Send Ctrl+Alt+Del
        = ⌃⌘M | Switch between absolute and relative mouse
        = ⌃⌘I | Virtual media (ISO images)
        = ⌃⌘R | Reconnect the video
        = ⌃⌘F | Enter or leave full screen
        = ⌃⌘T | Hide or show the toolbar in full screen
        = ⌥⌘V | Paste the clipboard as typing
        = ⌃⌥ | Release a captured mouse (relative mode)

        Other keys, including most ⌘ shortcuts, go to the remote machine while the console is in front. ⌘ is sent as the Windows (Super) key.
        """)

    static let troubleshooting = HelpTopic(
        "troubleshooting", title: "Troubleshooting", symbol: "wrench.and.screwdriver",
        keywords: ["problem", "error", "not working", "can't connect", "cannot connect", "keychain prompt", "password prompt", "black screen", "no signal", "local network", "permission", "reach"],
        body: """
        ## "Couldn't reach the device"
        - Check the address with **Test Connection** in the device editor, and that the device's web page opens in a browser.
        - The first time, macOS asks whether KVM Console may use the local network. If you said no, turn it on in **System Settings > Privacy & Security > Local Network**.
        - Away from home, the Tailscale address is used: make sure Tailscale is connected on this Mac.
        - A NanoKVM on plain HTTP can only be reached by IP address, a `.local` name, a bare host name or a `*.ts.net` name. See [Sipeed NanoKVM](help:nanokvm).

        ## "The username or password was rejected"
        Edit the device and type the password again. With two-factor authentication on, add the current code to the end of the password.

        ## A certificate was refused
        See [Certificates and Custom CAs](help:certificates). After replacing a device's certificate on purpose, edit the device and press **Forget Certificate**.

        ## No picture, or "No video signal"
        - The machine may be off, asleep, or on another Switch port. Press a key, or switch ports.
        - Choose **Console > Reconnect Video** (⌃⌘R).
        - If H.264 won't connect the app falls back to MJPEG by itself; the **Video** menu says why.

        ## The mouse doesn't line up, or doesn't move in a BIOS
        Try the other mouse mode with ⌃⌘M. See [Keyboard and Mouse](help:keyboard-mouse). In relative mode, press Control+Option to get your cursor back.

        ## Wrong characters when typing or pasting
        Keys are sent by position, so the remote machine's keyboard layout decides the character. Paste uses the PiKVM's keymap (US by default), so set the remote machine to the same layout.

        ## No sound
        Sound needs H.264 video and a PiKVM that sends audio; the **Audio** menu only appears when it does. Check that it isn't muted. NanoKVMs don't send sound to the app yet.

        ## Microphone or camera passthrough is missing
        The menu only appears when the PiKVM offers them. Turn on the USB microphone or webcam in [Configuring a PiKVM](help:configure-pikvm) and reboot it.

        ## The Openterface doesn't respond
        Quit the Openterface app, unplug the unit and plug it in again, then press **Look Again** in the device editor. **File > USB Devices…** shows whether the Mac sees its camera, serial port and audio. Allow camera and microphone access in System Settings if you said no.

        ## macOS keeps asking to use Keychain items
        A development build signed "to run locally" looks like a new app after each rebuild. Choose **Always Allow**, or build with a signing team as described in the README.
        """)
}
