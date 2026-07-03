#version 460 core

#include <flutter/runtime_effect.glsl>

// Local line-clear snap shader. See THIRD_PARTY_NOTICES.md.

#define min_movement_angle -2.25
#define max_movement_angle -0.72
#define movement_angles_count 12
#define movement_angle_step ((max_movement_angle - min_movement_angle) / movement_angles_count)
#define pi 3.14159265359

uniform float animationValue;
uniform float particleLifetime;
uniform float fadeOutDuration;
uniform float particlesInRow;
uniform float particlesInColumn;
uniform float particleSpeed;
uniform float particleHdrBoost;
uniform float particleGlowBoost;
uniform vec2 uSize;
uniform sampler2D uImageTexture;

out vec4 fragColor;

float delayForX(float x) {
  return (1.0 - particleLifetime) * x;
}

float randomAngle(int i) {
  float r = fract(sin(float(i) * 31.415 + 9.73) * 43758.5453);
  return min_movement_angle + floor(r * movement_angles_count) * movement_angle_step;
}

vec3 hdrParticleColor(vec3 color) {
  float maxChannel = max(max(color.r, color.g), color.b);
  if (maxChannel <= 0.0) {
    return color;
  }

  vec3 hue = color / maxChannel;
  vec3 saturatedHue = pow(clamp(hue, 0.0, 1.0), vec3(1.35));
  return saturatedHue * maxChannel * particleHdrBoost;
}

int particleIndexFor(vec2 point, float angle, float particleWidth, float particleHeight) {
  float x0 = (point.x - animationValue * cos(angle) * particleSpeed) /
      (1.0 - (1.0 - particleLifetime) * cos(angle) * particleSpeed);
  float delay = delayForX(x0);
  float y0 = point.y - (animationValue - delay) * sin(angle) * particleSpeed;

  if (angle <= -pi / 2.0 && point.x >= x0) {
    return int(point.x / particleWidth) + int(point.y / particleHeight) * int(particlesInRow);
  }
  if (angle >= -pi / 2.0 && point.x < x0) {
    return int(point.x / particleWidth) + int(point.y / particleHeight) * int(particlesInRow);
  }
  return int(x0 / particleWidth) + int(y0 / particleHeight) * int(particlesInRow);
}

void main() {
  vec2 uv = FlutterFragCoord().xy / uSize.xy;
  float particleWidth = 1.0 / particlesInRow;
  float particleHeight = 1.0 / particlesInColumn;
  float particlesCount = particlesInRow * particlesInColumn;

  for (float searchAngle = min_movement_angle; searchAngle <= max_movement_angle; searchAngle += movement_angle_step) {
    int i = particleIndexFor(uv, searchAngle, particleWidth, particleHeight);
    if (i < 0 || float(i) >= particlesCount) {
      continue;
    }

    float angle = randomAngle(i);
    vec2 grid = vec2(mod(float(i), particlesInRow), floor(float(i) / particlesInRow));
    vec2 center = (grid + vec2(0.5)) * vec2(particleWidth, particleHeight);
    float delay = delayForX(center.x);
    float t = max(0.0, animationValue - delay);
    vec2 sourceUv = vec2(
      uv.x - t * cos(angle) * particleSpeed,
      uv.y - t * sin(angle) * particleSpeed
    );

    vec2 minBounds = center - vec2(particleWidth, particleHeight) * 0.5;
    vec2 maxBounds = center + vec2(particleWidth, particleHeight) * 0.5;
    if (sourceUv.x >= minBounds.x && sourceUv.x <= maxBounds.x &&
        sourceUv.y >= minBounds.y && sourceUv.y <= maxBounds.y) {
      vec4 color = texture(uImageTexture, sourceUv);
      float fadeAge = max(0.0, t - (particleLifetime - fadeOutDuration));
      float opacity = max(0.0, 1.0 - fadeAge / fadeOutDuration);
      vec2 local = (sourceUv - center) / vec2(particleWidth, particleHeight);
      float coreGlow = smoothstep(0.82, 0.0, length(local));
      float glow = 1.0 + particleGlowBoost * coreGlow;
      fragColor = vec4(
        hdrParticleColor(color.rgb) * glow * opacity,
        color.a * opacity
      );
      return;
    }
  }

  fragColor = vec4(0.0);
}
