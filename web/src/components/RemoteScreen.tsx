import React, { useEffect, useRef, useCallback } from 'react';
import type { InputEvent } from '../lib/protocol';

interface RemoteScreenProps {
  /** Latest JPEG frame as a Blob URL (revoked automatically after drawing). */
  frameUrl: string | null;
  onInput: (event: InputEvent) => void;
  active: boolean;
}

/**
 * Renders incoming JPEG frames on a canvas and converts local pointer/keyboard
 * events into InputEvent objects forwarded to the remote agent.
 */
export const RemoteScreen: React.FC<RemoteScreenProps> = ({ frameUrl, onInput, active }) => {
  const canvasRef = useRef<HTMLCanvasElement>(null);
  const containerRef = useRef<HTMLDivElement>(null);
  const imgRef = useRef<HTMLImageElement | null>(null);

  // Draw new frame whenever frameUrl changes
  useEffect(() => {
    if (!frameUrl || !canvasRef.current) return;

    const canvas = canvasRef.current;
    const ctx = canvas.getContext('2d');
    if (!ctx) return;

    const img = new Image();
    imgRef.current = img;
    img.onload = () => {
      // Resize canvas to match the frame (only when dimensions change)
      if (canvas.width !== img.naturalWidth || canvas.height !== img.naturalHeight) {
        canvas.width = img.naturalWidth;
        canvas.height = img.naturalHeight;
      }
      ctx.drawImage(img, 0, 0);
      URL.revokeObjectURL(frameUrl); // free memory
    };
    img.src = frameUrl;
  }, [frameUrl]);

  // Normalise pointer position to 0–1 coordinates
  const normalise = useCallback(
    (e: React.MouseEvent): { nx: number; ny: number } => {
      const rect = containerRef.current!.getBoundingClientRect();
      return {
        nx: (e.clientX - rect.left) / rect.width,
        ny: (e.clientY - rect.top) / rect.height,
      };
    },
    [],
  );

  const handleMouseMove = useCallback(
    (e: React.MouseEvent) => {
      if (!active) return;
      onInput({ type: 'mousemove', ...normalise(e) });
    },
    [active, onInput, normalise],
  );

  const handleMouseDown = useCallback(
    (e: React.MouseEvent) => {
      if (!active) return;
      e.preventDefault();
      containerRef.current?.focus();
      onInput({ type: 'mousedown', button: e.button, ...normalise(e) });
    },
    [active, onInput, normalise],
  );

  const handleMouseUp = useCallback(
    (e: React.MouseEvent) => {
      if (!active) return;
      onInput({ type: 'mouseup', button: e.button, ...normalise(e) });
    },
    [active, onInput, normalise],
  );

  const handleWheel = useCallback(
    (e: React.WheelEvent) => {
      if (!active) return;
      e.preventDefault();
      onInput({ type: 'scroll', dx: e.deltaX, dy: e.deltaY });
    },
    [active, onInput],
  );

  const handleKeyDown = useCallback(
    (e: React.KeyboardEvent) => {
      if (!active) return;
      if (e.ctrlKey && ['r', 'l', 'w', 't'].includes(e.key.toLowerCase())) return;
      e.preventDefault();
      onInput({
        type: 'keydown',
        key: e.key,
        code: e.code,
        ctrl: e.ctrlKey,
        alt: e.altKey,
        shift: e.shiftKey,
        meta: e.metaKey,
      });
    },
    [active, onInput],
  );

  const handleKeyUp = useCallback(
    (e: React.KeyboardEvent) => {
      if (!active) return;
      onInput({
        type: 'keyup',
        key: e.key,
        code: e.code,
        ctrl: e.ctrlKey,
        alt: e.altKey,
        shift: e.shiftKey,
        meta: e.metaKey,
      });
    },
    [active, onInput],
  );

  return (
    <div
      ref={containerRef}
      className={`remote-screen${active ? ' active' : ''}`}
      tabIndex={0}
      onMouseMove={handleMouseMove}
      onMouseDown={handleMouseDown}
      onMouseUp={handleMouseUp}
      onWheel={handleWheel}
      onKeyDown={handleKeyDown}
      onKeyUp={handleKeyUp}
      onContextMenu={(e) => e.preventDefault()}
    >
      {frameUrl !== null || active ? (
        <canvas ref={canvasRef} className="remote-canvas" />
      ) : (
        <div className="screen-placeholder">Not connected</div>
      )}
    </div>
  );
};
