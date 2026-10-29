// Store links. Leave a value empty until that build is published and its
// button stays disabled with a "Coming soon" note.
const DOWNLOADS = {
  ios: "",
  mac: "",
};

// Mirrors the app's gesture contract (PRD §5), scaled down for the mockup:
// release inside the edge zone, moving outward fast enough, after enough travel.
const MIN_VELOCITY = 0.5; // px per ms, about 500 pt/s
const MIN_TRAVEL = 40;

const reduceMotion = matchMedia("(prefers-reduced-motion: reduce)");

setUpDownloads();
setUpDemo();
document.getElementById("year").textContent = new Date().getFullYear();

function setUpDownloads() {
  let missing = false;
  for (const link of document.querySelectorAll("[data-download]")) {
    const url = DOWNLOADS[link.dataset.download];
    if (url) {
      link.href = url;
    } else {
      missing = true;
      link.removeAttribute("href");
      link.setAttribute("aria-disabled", "true");
      link.setAttribute("role", "link");
    }
  }
  if (missing) {
    document.getElementById("downloadNote").textContent =
      "Coming soon. Spatial Bridge is in pre-release. Requires iOS 26 and macOS 26 or later.";
  }
}

function setUpDemo() {
  const scene = document.getElementById("scene");
  const phoneScreen = document.getElementById("phoneScreen");
  const photo = document.getElementById("photo");
  const desktop = document.getElementById("desktop");
  const slot = document.getElementById("landingSlot");
  const toast = document.getElementById("toast");
  const hint = document.getElementById("phoneHint");
  const bar = document.querySelector("#progress span");
  const wireLog = document.getElementById("wireLog");
  const wireState = document.getElementById("wireState");

  // Message names match the real protocol (FRD §4). The file and hash are placeholders.
  const log = (from, msg, detail = "", ok = false) => {
    const line = document.createElement("li");
    if (ok) line.className = "ok";
    for (const [cls, text] of [["from", from], ["msg", msg], ["detail", detail]]) {
      const cell = document.createElement("span");
      cell.className = cls;
      cell.textContent = text;
      line.append(cell);
    }
    wireLog.append(line);
  };
  const setWire = (state) => {
    wireState.textContent = state;
    wireState.className = state === "committed" ? "done" : state === "idle" ? "" : "busy";
  };

  let drag = null;
  let busy = false;
  let dragged = false;
  let interacted = false;

  const isArmed = () => {
    const zone = phoneScreen.getBoundingClientRect();
    return photo.getBoundingClientRect().top < zone.top + zone.height * 0.22;
  };

  photo.addEventListener("pointerdown", (e) => {
    if (busy) return;
    interacted = true;
    dragged = false;
    photo.setPointerCapture(e.pointerId);
    drag = { x: e.clientX, y: e.clientY, dx: 0, dy: 0, lastY: e.clientY, lastT: e.timeStamp, vy: 0 };
  });

  photo.addEventListener("pointermove", (e) => {
    if (!drag) return;
    drag.dx = e.clientX - drag.x;
    drag.dy = e.clientY - drag.y;
    const dt = e.timeStamp - drag.lastT;
    if (dt > 0) drag.vy = (e.clientY - drag.lastY) / dt;
    drag.lastY = e.clientY;
    drag.lastT = e.timeStamp;
    if (Math.hypot(drag.dx, drag.dy) > 6) dragged = true;
    photo.style.transform = `translate(${drag.dx * 0.6}px, ${Math.min(drag.dy, 30)}px) rotate(${drag.dx * 0.05}deg)`;
    scene.classList.toggle("armed", isArmed());
  });

  const endDrag = () => {
    if (!drag) return;
    const thrown = isArmed() && drag.vy < -MIN_VELOCITY && -drag.dy >= MIN_TRAVEL;
    drag = null;
    scene.classList.remove("armed");
    if (thrown) {
      send();
    } else if (dragged) {
      photo.animate([{ transform: photo.style.transform }, { transform: "none" }], { duration: 260, easing: "cubic-bezier(.3,1.4,.5,1)" });
      photo.style.transform = "";
      hint.textContent = "Flick a little faster";
    }
  };
  photo.addEventListener("pointerup", endDrag);
  photo.addEventListener("pointercancel", endDrag);

  // A tap or keyboard press is the accessible Send fallback.
  photo.addEventListener("click", () => {
    interacted = true;
    if (!dragged && !busy) send();
    dragged = false;
  });

  async function send() {
    busy = true;
    hint.textContent = "Sending…";
    scene.classList.add("sending");
    wireLog.replaceChildren();
    setWire("sending");
    log("iPhone", "TRANSFER_OFFER", "sunset.heic · 2.4 MB · bottom edge");
    wait(120).then(() => log("Mac", "TRANSFER_ACCEPT"));
    wait(480).then(() => log("Mac", "PROGRESS", "1.2 of 2.4 MB received"));
    const still = reduceMotion.matches;

    const exit = photo.offsetTop + photo.offsetHeight + 20;
    const leaving = still
      ? photo.animate([{ opacity: 1 }, { opacity: 0 }], { duration: 150, fill: "forwards" })
      : photo.animate(
          [{ transform: photo.style.transform || "none" }, { transform: `translateY(${-exit}px) scale(0.9)`, opacity: 0 }],
          { duration: 240, easing: "cubic-bezier(.5,0,.9,.6)", fill: "forwards" },
        );
    photo.style.transform = "";

    // The phone sits below the Mac, so the photo enters from the bottom edge.
    const landed = document.createElement("div");
    landed.className = "landed";
    Object.assign(landed.style, {
      left: slot.offsetLeft + "px",
      top: slot.offsetTop + "px",
      width: slot.offsetWidth + "px",
      height: slot.offsetHeight + "px",
    });
    desktop.append(landed);
    const rise = desktop.offsetHeight - slot.offsetTop;
    const arriving = still
      ? landed.animate([{ opacity: 0 }, { opacity: 1 }], { duration: 200, fill: "both" })
      : landed.animate(
          [
            { transform: `translateY(${rise}px) scale(0.8) rotate(-4deg)` },
            { transform: "translateY(-6px) scale(1.03) rotate(1deg)", offset: 0.75 },
            { transform: "none" },
          ],
          { duration: 300, delay: 160, easing: "cubic-bezier(.2,.8,.3,1)", fill: "both" },
        );

    const progress = bar.animate([{ width: "0%" }, { width: "100%" }], { duration: 900, easing: "ease-in-out", fill: "forwards" });
    await Promise.all([leaving.finished, arriving.finished, progress.finished]);
    log("iPhone", "COMPLETE", "sha256 9f2c…e41a");
    hint.textContent = "Waiting for Mac…";
    setWire("verifying");
    await wait(450);

    // Success shows only once the Mac sends COMMITTED, just like the app.
    log("Mac", "COMMITTED", "hash matches · saved to Desktop", true);
    setWire("committed");
    toast.classList.add("show");
    hint.textContent = "Sent";
    await wait(2400);

    toast.classList.remove("show");
    scene.classList.remove("sending");
    await landed.animate([{ opacity: 1 }, { opacity: 0 }], { duration: 300, fill: "forwards" }).finished;
    landed.remove();
    leaving.cancel();
    progress.cancel();
    photo.animate([{ opacity: 0, transform: "scale(0.94)" }, { opacity: 1, transform: "none" }], { duration: 260 });
    hint.textContent = "Drag up and let go";
    setWire("idle");
    busy = false;
  }

  // Nudge the photo now and then until someone tries it.
  if (!reduceMotion.matches) {
    const nudge = setInterval(() => {
      if (interacted) return clearInterval(nudge);
      if (busy || drag) return;
      photo.animate(
        [{ transform: "none" }, { transform: "translateY(-14px)" }, { transform: "none" }],
        { duration: 900, easing: "cubic-bezier(.4,0,.2,1)" },
      );
    }, 3500);
  }
}

function wait(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}
