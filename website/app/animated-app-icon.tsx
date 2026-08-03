"use client";

import Image from "next/image";
import { motion, useReducedMotion, useSpring } from "motion/react";
import { useEffect } from "react";

const MAX_TILT_DEGREES = 20;
const SPRING = { stiffness: 150, damping: 20, mass: 0.4 };

export function AnimatedAppIcon() {
  const shouldReduceMotion = useReducedMotion();
  const rotateX = useSpring(0, SPRING);
  const rotateY = useSpring(0, SPRING);

  useEffect(() => {
    if (shouldReduceMotion) {
      rotateX.jump(0);
      rotateY.jump(0);
      return;
    }

    const precisePointer = window.matchMedia("(hover: hover) and (pointer: fine)");

    const resetTilt = () => {
      rotateX.set(0);
      rotateY.set(0);
    };

    const handlePointerMove = (event: PointerEvent) => {
      if (!precisePointer.matches) {
        return;
      }

      const normalizedX = (event.clientX / window.innerWidth) * 2 - 1;
      const normalizedY = (event.clientY / window.innerHeight) * 2 - 1;

      rotateX.set(normalizedY * -MAX_TILT_DEGREES);
      rotateY.set(normalizedX * MAX_TILT_DEGREES);
    };

    const handlePointerCapabilityChange = () => {
      if (!precisePointer.matches) {
        rotateX.jump(0);
        rotateY.jump(0);
      }
    };

    window.addEventListener("pointermove", handlePointerMove, { passive: true });
    window.addEventListener("blur", resetTilt);
    document.documentElement.addEventListener("pointerleave", resetTilt);
    precisePointer.addEventListener("change", handlePointerCapabilityChange);

    return () => {
      window.removeEventListener("pointermove", handlePointerMove);
      window.removeEventListener("blur", resetTilt);
      document.documentElement.removeEventListener("pointerleave", resetTilt);
      precisePointer.removeEventListener("change", handlePointerCapabilityChange);
    };
  }, [rotateX, rotateY, shouldReduceMotion]);

  return (
    <motion.div
      className="w-26 sm:w-30 md:w-32"
      style={{
        rotateX,
        rotateY,
        transformPerspective: 700,
        transformStyle: "preserve-3d",
        willChange: "transform",
      }}
    >
      <Image
        className="h-auto w-full"
        src="/current-icon.png"
        alt="current app icon"
        width={128}
        height={128}
        priority
      />
    </motion.div>
  );
}
