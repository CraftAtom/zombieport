<p align="center">
  <img src="docs/logo.png" width="128" alt="Zombieport logo: a network port with crossed-out eyes">
</p>

# Zombieport

Zombieport is a macOS menu bar app that finds development servers that you forgot to
stop, such as Node.js, Bun, Deno, Python, and workerd processes that still hold a
Transmission Control Protocol (TCP) port. For each server, it shows the port, project name, Git repository, command,
working directory, process ID (PID), and uptime. You can select one or more servers and
stop them.

## Build and install the app

Zombieport requires macOS 14 or later and the Xcode command line tools.

1. Clone the repository:

   ```sh
   git clone https://github.com/CraftAtom/zombieport.git
   cd zombieport
   ```

2. To build `build/Zombieport.app`, run the build script:

   ```sh
   ./build.sh
   ```

3. To copy the app to `/Applications`, run the script with the `--install` flag:

   ```sh
   ./build.sh --install
   ```

4. To start Zombieport when you log in, add it in **System Settings** > **General** >
   **Login Items**.

## Use the window

To open the Zombieport window, click the menu bar icon. If the icon is hidden, for example
behind the camera housing, open Zombieport again from Spotlight or Finder. To see the
**Quit** option, right-click the icon.

- To select processes, click a row. To select more than one, Command-click or
  Shift-click. To select every row, click **Select All**.
- To stop the selected processes, click **Kill**, or click the list and press Delete. Zombieport
  sends `SIGTERM`, then sends `SIGKILL` if a process still runs after two seconds.
- To filter the list by name, port, path, or PID, type in the search field.
- To open a port in your browser, click the port. To sort the list, click a column
  header.
- To open a server's first port in your browser, double-click its row.
- To stop a process immediately, right-click its row and click **Force Kill (SIGKILL)**.
  The same menu has **Reveal in Finder**, **Copy Path**, **Copy Command**, and
  **Copy PID**.
- To show every process that listens on a TCP port, not only development runtimes,
  click **All Listeners** in the toolbar.

Under each name, Zombieport shows the Git repository and a short form of the command,
such as `my-app · tsx src/server.ts`. The project name comes from the `name` field in `package.json` in the process's
working directory. If that file doesn't exist, Zombieport uses the directory name.
The list refreshes every five seconds.

## List servers from the terminal

To print the list without opening the window, run the binary with `--list`. Add `--all`
to include every listener.

```sh
build/Zombieport.app/Contents/MacOS/Zombieport --list
```

## Regenerate the icon

The app icon and the logo come from `scripts/make-icon.swift`. To regenerate
`Resources/AppIcon.icns` and `docs/logo.png` after you change the drawing code, run
the script:

```sh
swift scripts/make-icon.swift
```

## License

Zombieport is available under the MIT License. For details, see [the license file](LICENSE).
