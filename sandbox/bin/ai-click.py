#!/usr/bin/env python3
"""Moves the pointer smoothly to (x, y), clicks, and flashes a small "AI"
badge at the click point — so a human watching the desktop over VNC can tell
an agent action just happened, as opposed to their own mouse input, without
a persistent cursor overlay that would misattribute the human's own
movements if they ever take manual control.
"""
import subprocess
import sys
import time


def get_pos() -> tuple[int, int]:
    out = subprocess.run(
        ["xdotool", "getmouselocation", "--shell"], capture_output=True, text=True, check=True
    ).stdout
    values = dict(line.split("=", 1) for line in out.strip().splitlines() if "=" in line)
    return int(values["X"]), int(values["Y"])


def move_to(x: int, y: int) -> None:
    subprocess.run(["xdotool", "mousemove", str(x), str(y)], check=True)


def show_badge(x: int, y: int) -> None:
    try:
        import tkinter as tk
    except Exception:
        return  # the click already happened; a missing badge is cosmetic only
    try:
        root = tk.Tk()
        root.overrideredirect(True)  # bypass the window manager entirely
        root.attributes("-topmost", True)
        label = tk.Label(
            root, text=" \U0001F916 AI ", bg="#7c3aed", fg="white",
            font=("Sans", 11, "bold"), padx=6, pady=2,
        )
        label.pack()
        root.update_idletasks()
        width, height = root.winfo_width(), root.winfo_height()
        # Offset up-and-right of the click point, not centered on it, so the
        # badge itself is never sitting exactly where the next click lands.
        root.geometry(f"{width}x{height}+{x + 14}+{max(0, y - height - 6)}")
        root.after(700, root.destroy)
        root.mainloop()
    except Exception:
        pass


def main() -> None:
    target_x, target_y = int(sys.argv[1]), int(sys.argv[2])
    button = sys.argv[3] if len(sys.argv) > 3 else "1"

    start_x, start_y = get_pos()
    steps = 12
    for i in range(1, steps + 1):
        t = i / steps
        move_to(
            round(start_x + (target_x - start_x) * t),
            round(start_y + (target_y - start_y) * t),
        )
        time.sleep(0.012)

    subprocess.run(["xdotool", "click", button], check=True)
    show_badge(target_x, target_y)


if __name__ == "__main__":
    main()
