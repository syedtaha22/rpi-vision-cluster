# Real-Time Sobel Edge Detection

A small C++ web app that captures camera frames in the browser, sends them to a local server over WebSocket, applies Sobel edge detection on the server, and streams the processed image back to the browser in real time.

## File Structure

```sh
.
├── include
│   ├── HttpServer.h        # HTTP server class definition
│   ├── Logger.h            # Logger class definition
│   └── SobelProcessor.h    # Sobel edge detection class definition
├── public  
│   ├── index.html          # Browser UI
│   ├── script.js           # Client-side logic for capturing and sending frames
│   └── style.css           # Styles for the UI
├── src
│   ├── HttpServer.cpp      # HTTP server implementation
│   ├── Logger.cpp          # Logger implementation
│   └── SobelProcessor.cpp  # Sobel edge detection implementation
├── main.cpp                # Main entry point for the server
└── Makefile                # Makefile for building the server
```

## Architecture

The project is split into three layers:

- **Browser UI**: `public/index.html`, `public/style.css`, and `public/script.js`
- **Server runtime**: `main.cpp` and the C++ classes in `include/` and `src/`
- **Persistence and diagnostics**: `logs/server.log`

### Server Components

- `HttpServer`
  - Serves static files from `public/`
  - Exposes `/health` and `/ready`
  - Upgrades `/ws` requests to WebSocket connections
  - Handles one client per detached thread
  - Returns processed image frames to the browser
- `SobelProcessor`
  - Accepts RGBA frames
  - Converts them to grayscale
  - Runs Sobel edge detection
  - Returns RGBA output frames
- `Logger`
  - Writes application logs to `logs/server.log`
  - Prints access-style request logs to the terminal

### Browser Components

- `index.html` defines the controls and two panes
- `script.js`:
  - captures the camera stream
  - draws each frame into an offscreen capture canvas
  - sends raw RGBA frame bytes to the server
  - receives processed bytes and paints them into the visible canvas
- `style.css` controls layout, centered display, and the processed-only mode when the raw feed is hidden

## Communication Protocol

The app uses two protocols over plain HTTP on a local port.

### 1. HTTP/1.1

The server responds to standard browser requests for static assets:

- `GET /` -> serves `public/index.html`
- `GET /style.css` -> serves the stylesheet
- `GET /script.js` -> serves the client logic
- `GET /health` -> returns `{"status":"ok"}`
- `GET /ready` -> returns `{"ready":true}`

### 2. WebSocket (`/ws`)

The browser upgrades a request to WebSocket using the RFC 6455 handshake:

- Client sends `Sec-WebSocket-Key`
- Server computes `Sec-WebSocket-Accept`
- Connection switches to binary WebSocket frames

After the upgrade:

- The browser sends raw frame bytes as **binary messages**
- The frame size is `width * height * 4` bytes for RGBA data
- The current pipeline uses `640x480` frames
- The server processes the bytes with Sobel edge detection
- The server returns the processed RGBA frame as a binary WebSocket message

### Frame Flow

1. Browser captures a frame from the camera
2. Browser copies it into an offscreen canvas
3. Browser sends the RGBA pixel buffer over WebSocket
4. Server applies Sobel edge detection
5. Server sends processed RGBA bytes back
6. Browser renders the result in the visible canvas

## Logging

Runtime logs are written to `logs/server.log` and include:

- startup messages
- request handling
- WebSocket lifecycle events
- warnings and errors
- access-log style request lines

## Build

```bash
make
```

This produces `bin/server`.

## Run

```bash
./bin/server 8080
```

Then open:

```text
http://127.0.0.1:8080/
```

## Notes

- The raw feed can be hidden from the UI, leaving only the processed feed centered on the page.
- The server currently expects `640x480` RGBA frames from the client.
- `bin/` and `logs/` are runtime/build outputs and may be ignored by git depending on the local ignore rules.
