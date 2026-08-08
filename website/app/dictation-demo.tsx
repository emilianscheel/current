"use client";

import Image from "next/image";
import { motion } from "motion/react";
import {
  useCallback,
  useEffect,
  useRef,
  useState,
  type KeyboardEvent,
  type PointerEvent,
} from "react";

type DemoPhase = "idle" | "active" | "fading" | "releasing";

const PHASE_DURATION: Record<DemoPhase, number> = {
  idle: 3_000,
  active: 5_350,
  fading: 300,
  releasing: 350,
};

const NEXT_PHASE: Record<DemoPhase, DemoPhase> = {
  idle: "active",
  active: "fading",
  fading: "releasing",
  releasing: "idle",
};

const NOTCH_EASE = [0.22, 1, 0.36, 1] as const;
const EXPANSION_BEZIER = [0.25, 1, 0.5, 1] as const;
const PILL_HEIGHTS = [6, 10, 14, 10, 6];

export function DictationDemo() {
  const [phase, setPhase] = useState<DemoPhase>("idle");
  const [isManualHold, setIsManualHold] = useState(false);
  const manualHoldRef = useRef(false);
  const pointerIdRef = useRef<number | null>(null);

  const isExpanded = phase === "active" || phase === "fading";
  const isRecording = phase === "active";
  const isPressed = isExpanded;

  useEffect(() => {
    if (isManualHold) {
      return;
    }

    const timeout = window.setTimeout(() => {
      setPhase((currentPhase) => NEXT_PHASE[currentPhase]);
    }, PHASE_DURATION[phase]);

    return () => window.clearTimeout(timeout);
  }, [isManualHold, phase]);

  const beginManualHold = useCallback(() => {
    if (manualHoldRef.current) {
      return;
    }

    manualHoldRef.current = true;
    setIsManualHold(true);
    setPhase("active");
  }, []);

  const endManualHold = useCallback(() => {
    if (!manualHoldRef.current) {
      return;
    }

    manualHoldRef.current = false;
    pointerIdRef.current = null;
    setIsManualHold(false);
    setPhase("releasing");
  }, []);

  useEffect(() => {
    window.addEventListener("blur", endManualHold);
    return () => window.removeEventListener("blur", endManualHold);
  }, [endManualHold]);

  const handlePointerDown = (event: PointerEvent<HTMLButtonElement>) => {
    if (event.button !== 0) {
      return;
    }

    event.preventDefault();
    pointerIdRef.current = event.pointerId;
    event.currentTarget.setPointerCapture(event.pointerId);
    beginManualHold();
  };

  const handlePointerEnd = (event: PointerEvent<HTMLButtonElement>) => {
    if (pointerIdRef.current !== event.pointerId) {
      return;
    }

    if (event.currentTarget.hasPointerCapture(event.pointerId)) {
      event.currentTarget.releasePointerCapture(event.pointerId);
    }
    endManualHold();
  };

  const handleKeyDown = (event: KeyboardEvent<HTMLButtonElement>) => {
    if (event.key !== " " && event.key !== "Enter") {
      return;
    }

    event.preventDefault();
    if (!event.repeat) {
      beginManualHold();
    }
  };

  const handleKeyUp = (event: KeyboardEvent<HTMLButtonElement>) => {
    if (event.key !== " " && event.key !== "Enter") {
      return;
    }

    event.preventDefault();
    endManualHold();
  };

  return (
    <>
      <div className="dictation-notch-shell" aria-hidden="true">
        <div className="dictation-notch-base" />

        <motion.div
          className="dictation-notch-expanded"
          data-expanded={isExpanded}
          animate={{
            width: isExpanded ? 340 : 0,
            height: isExpanded ? 52 : 0,
          }}
          initial={false}
          transition={{
            width: { duration: 0.38, ease: EXPANSION_BEZIER },
            height: { duration: 0.38, ease: EXPANSION_BEZIER },
          }}
        >
          <motion.div
            className="dictation-notch-content"
            animate={{
              opacity: isRecording ? 1 : 0,
            }}
            initial={false}
            transition={{
              duration: isRecording ? 0.22 : 0.25,
              delay: isRecording ? 0.12 : 0,
              ease: NOTCH_EASE,
            }}
          >
            <Image
              className="dictation-mail-icon"
              src="/mail-icon-transparent.png"
              alt=""
              width={48}
              height={48}
            />

            <div className="dictation-audio-meter">
              {PILL_HEIGHTS.map((height, index) => (
                <motion.span
                  // The fixed index maps each pill to a distinct waveform height.
                  key={index}
                  className="dictation-audio-pill"
                  style={{ height }}
                  animate={
                    isRecording
                      ? { scaleY: [0.45, 1, 0.62, 1.16, 0.45] }
                      : { scaleY: 0.45 }
                  }
                  transition={
                    isRecording
                      ? {
                          duration: 0.9,
                          delay: index * 0.08,
                          ease: "easeInOut",
                          repeat: Number.POSITIVE_INFINITY,
                        }
                      : { duration: 0.18 }
                  }
                />
              ))}
            </div>
          </motion.div>
        </motion.div>
      </div>

      <motion.button
        type="button"
        className="dictation-fn-key"
        data-pressed={isPressed}
        aria-label="Hold to preview dictation"
        aria-pressed={isPressed}
        animate={{
          y: isPressed ? 3 : 0,
          scale: isPressed ? 0.99 : 1,
        }}
        initial={false}
        transition={{ duration: 0.18, ease: NOTCH_EASE }}
        onPointerDown={handlePointerDown}
        onPointerUp={handlePointerEnd}
        onPointerCancel={handlePointerEnd}
        onLostPointerCapture={endManualHold}
        onKeyDown={handleKeyDown}
        onKeyUp={handleKeyUp}
        onBlur={endManualHold}
      >
        <span className="dictation-fn-label">fn</span>
        <span className="dictation-globe" aria-hidden="true">
          {"\u{1F310}\u{FE0E}"}
        </span>
      </motion.button>
    </>
  );
}
