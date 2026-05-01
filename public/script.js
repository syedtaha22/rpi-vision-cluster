/**
 * @file Client-side WebSocket frame streaming and Sobel edge detection visualization.
 * Captures raw camera feed at 640x480, sends frames to server via WebSocket,
 * and displays received processed (Sobel edge-detected) frames.
 * 
 * @date 1st May, 2026
 * @author Syed Taha
 */

/** Frame width in pixels. Must match server-side FRAME_WIDTH. */
const FRAME_WIDTH = 640;

/** Frame height in pixels. Must match server-side FRAME_HEIGHT. */
const FRAME_HEIGHT = 480;

/** Total bytes per frame: width * height * 4 (RGBA). */
const FRAME_BYTES = FRAME_WIDTH * FRAME_HEIGHT * 4;

/** Target frame rate in frames per second. */
const FPS = 30;

/* DOM Elements */
/** Start/Stop button. */
const toggleBtn = document.getElementById("toggleBtn");

/** Hide/Show raw feed toggle button. */
const rawToggleBtn = document.getElementById("rawToggleBtn");

/** Video element displaying raw camera stream. */
const rawVideo = document.getElementById("rawVideo");

/** Offscreen canvas for capturing raw frames from video element. */
const captureCanvas = document.getElementById("captureCanvas");

/** 2D rendering context for capture canvas. */
const captureCtx = captureCanvas.getContext("2d", { willReadFrequently: true });

/** Visible canvas for displaying processed (Sobel edge-detected) frames. */
const processedCanvas = document.getElementById("processedCanvas");

/** 2D rendering context for processed canvas. */
const processedCtx = processedCanvas.getContext("2d");

/* Application State */
/** MediaStream from getUserMedia(); null when inactive. */
let stream = null;

/** WebSocket connection to server (/ws); null when disconnected. */
let ws = null;

/** IntervalID for capture loop; null when inactive. */
let captureTimer = null;

/** Whether camera capture and WebSocket transmission are active. */
let running = false;

/** Whether raw camera feed is visible in UI. */
let rawVisible = true;

/**
 * Toggle raw camera feed visibility and update UI.
 * @param {boolean} visible - If true, show raw feed; if false, hide and center processed feed.
 */
function setRawFeedVisible(visible) {
    rawVisible = visible;
    document.body.classList.toggle("raw-hidden", !visible);
    rawToggleBtn.textContent = visible ? "Hide Raw Feed" : "Show Raw Feed";
}

/**
 * Update Start/Stop button text to reflect current state.
 * @param {boolean} active - If true, display "Stop"; if false, display "Start".
 */
function setButtonState(active) {
    toggleBtn.textContent = active ? "Stop" : "Start";
}

/**
 * Stop all active operations: frame capture, WebSocket transmission, and media stream.
 * Closes timer, WebSocket connection, and device access.
 */
function stopAll() {
    if (captureTimer) {
        clearInterval(captureTimer);
        captureTimer = null;
    }

    if (ws) {
        ws.close();
        ws = null;
    }

    if (stream) {
        stream.getTracks().forEach((track) => track.stop());
        stream = null;
    }

    rawVideo.srcObject = null;
    running = false;
    setButtonState(false);
}

/**
 * Establish WebSocket connection to server (/ws endpoint).
 * Sets up binary frame reception and display on processed canvas.
 * @returns {Promise<void>} Resolves when WebSocket is ready (onopen event).
 * @throws {Error} Rejects on connection failure.
 */
function connectWebSocket() {
    return new Promise((resolve, reject) => {
        const socket = new WebSocket(`ws://${window.location.host}/ws`);
        socket.binaryType = "arraybuffer";

        socket.onopen = () => {
            ws = socket;
            resolve();
        };

        socket.onerror = () => {
            reject(new Error("Failed to connect WebSocket"));
        };

        socket.onclose = () => {
            if (running) {
                stopAll();
            }
        };

        /**
         * Handle incoming processed frame from server.
         * Expects RGBA binary data matching FRAME_BYTES size (640x480x4).
         * Renders frame to processedCanvas using CanvasRenderingContext2D.putImageData().
         */
        socket.onmessage = (event) => {
            const data = new Uint8ClampedArray(event.data);
            if (data.byteLength !== FRAME_BYTES) {
                return;
            }

            const img = new ImageData(data, FRAME_WIDTH, FRAME_HEIGHT);
            processedCtx.putImageData(img, 0, 0);
        };
    });
}

/**
 * Start camera capture and WebSocket transmission.
 * 1. Requests camera access via getUserMedia().
 * 2. Streams raw camera feed to rawVideo element.
 * 3. Connects to server WebSocket endpoint.
 * 4. Begins capture loop: extracts RGBA frame from video, sends via WebSocket at FPS rate.
 * @async
 * @throws {Error} From getUserMedia() if camera access denied or connectWebSocket() if connection fails.
 */
async function startAll() {
    stream = await navigator.mediaDevices.getUserMedia({
        video: {
            width: FRAME_WIDTH,
            height: FRAME_HEIGHT
        },
        audio: false
    });

    rawVideo.srcObject = stream;
    await rawVideo.play();
    await connectWebSocket();

    captureTimer = setInterval(() => {
        if (!ws || ws.readyState !== WebSocket.OPEN) {
            return;
        }

        captureCtx.drawImage(rawVideo, 0, 0, FRAME_WIDTH, FRAME_HEIGHT);
        const frame = captureCtx.getImageData(0, 0, FRAME_WIDTH, FRAME_HEIGHT);
        ws.send(frame.data.buffer);
    }, Math.round(1000 / FPS));

    running = true;
    setButtonState(true);
}

/**
 * Start/Stop button click handler.
 * Toggles between active capture (startAll) and stopped state (stopAll).
 */
toggleBtn.addEventListener("click", async () => {
    if (running) {
        stopAll();
        return;
    }

    try {
        await startAll();
    } catch (err) {
        console.error(err);
        stopAll();
        alert("Unable to start camera or WebSocket connection.");
    }
});

/**
 * Raw feed visibility toggle button click handler.
 * Switches between dual-pane (raw + processed) and centered processed-only views.
 */
rawToggleBtn.addEventListener("click", () => {
    setRawFeedVisible(!rawVisible);
});

/* Initialize UI: raw feed visible by default. */
setRawFeedVisible(true);
