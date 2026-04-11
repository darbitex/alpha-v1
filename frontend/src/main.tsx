import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import { App } from "./App";
import "./styles.css";

const root = document.getElementById("root");
if (!root) throw new Error("root not found");
createRoot(root).render(
  <StrictMode>
    <App />
  </StrictMode>,
);

// Signal to the cold-start retry bootstrap that React mounted successfully
// so it clears its retry counter.
(window as unknown as { __dbx_mounted?: () => void }).__dbx_mounted?.();
