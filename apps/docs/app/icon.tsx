import { ImageResponse } from "next/og";

// Route segment config — auto-serves the app favicon at /icon.
// force-static is required because next.config sets output: "export".
export const dynamic = "force-static";
export const size = { width: 32, height: 32 };
export const contentType = "image/png";

// "The Deck" — three cascading portrait cards, frontmost with a sky-blue
// accent rule. Rendered at 32×32 for the browser tab / favicon.
export default function Icon() {
  return new ImageResponse(
    (
      <svg
        width="32"
        height="32"
        viewBox="0 0 100 100"
        xmlns="http://www.w3.org/2000/svg"
      >
        <rect width="100" height="100" rx="22" fill="#0B1628" />
        <rect
          x="31"
          y="9"
          width="52"
          height="67"
          rx="5"
          fill="#FFFFFF"
          fillOpacity="0.20"
        />
        <rect
          x="23"
          y="17"
          width="52"
          height="67"
          rx="5"
          fill="#FFFFFF"
          fillOpacity="0.48"
        />
        <rect x="15" y="25" width="52" height="67" rx="5" fill="#FFFFFF" />
        <rect x="23" y="37" width="30" height="2.5" rx="1.25" fill="#38BDF8" />
        <rect
          x="23"
          y="45"
          width="37"
          height="1.8"
          rx="0.9"
          fill="#0B1628"
          fillOpacity="0.14"
        />
        <rect
          x="23"
          y="51"
          width="29"
          height="1.8"
          rx="0.9"
          fill="#0B1628"
          fillOpacity="0.14"
        />
        <rect
          x="23"
          y="57"
          width="34"
          height="1.8"
          rx="0.9"
          fill="#0B1628"
          fillOpacity="0.14"
        />
      </svg>
    ),
    { ...size }
  );
}
