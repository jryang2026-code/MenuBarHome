import { useEffect, useMemo, useRef, useState } from 'react';
import { Canvas, useFrame, useThree } from '@react-three/fiber';
import * as THREE from 'three';
import { OrbitControls as ThreeOrbitControls } from 'three/addons/controls/OrbitControls.js';
import { RoomEnvironment } from 'three/addons/environments/RoomEnvironment.js';
import { kelvinToHex, useHomeStore, type HoverTarget } from '../../store/homeStore';
import { playTactileSound } from '../../utils/tactileSound';
import {
  createAmberHaloTexture,
  createAppleOakTextures,
  createBoucleRugTexture,
  createClimatePuckTexture,
  createContactShadowTexture,
  createFeltMatTexture,
  createHardwoodFloorTextures,
  createKeyboardTexture,
  createLinenFabricTexture,
  createSunPatchTexture,
  createVinylDiscTexture,
  createWarmPlasterTexture,
  drawAcDisplayCanvas,
  drawIMacDisplayCanvas,
} from './studyTextures';

interface StudyScene3DProps {
  visible: boolean;
  reducedMotion: boolean;
  onReady: () => void;
  onFallback: () => void;
  onFocusSearch: () => void;
}

/** Custom Golden-Hour Sunset Sky Shader with layered twilight clouds & warm distant hill ridge */
const SUNSET_SKY_VERT = /* glsl */ `
  varying vec2 vUv;
  void main() {
    vUv = uv;
    gl_Position = projectionMatrix * modelViewMatrix * vec4(position, 1.0);
  }
`;

const SUNSET_SKY_FRAG = /* glsl */ `
  uniform float uWarmth;
  uniform float uSunReveal;
  varying vec2 vUv;
  void main() {
    vec3 lowerGlow = vec3(0.99, 0.67, 0.36);
    vec3 midApricot = vec3(0.91, 0.52, 0.37);
    vec3 upperTwilight = vec3(0.35, 0.45, 0.64);

    float h = clamp(vUv.y, 0.0, 1.0);
    vec3 sky = mix(lowerGlow, midApricot, smoothstep(0.06, 0.46, h));
    sky = mix(sky, upperTwilight, smoothstep(0.40, 0.95, h));

    // Low golden setting sun disc & warm Mie glow
    vec2 sunPos = vec2(0.46, 0.27);
    float d = length((vUv - sunPos) * vec2(1.0, 1.55));
    float disc = smoothstep(0.105, 0.038, d);
    float halo = exp(-d * 3.2) * 0.72;
    sky += vec3(1.0, 0.85, 0.58) * (disc * 0.96 + halo) * (0.72 + uSunReveal * 0.38);

    // Layered evening cloud wisps catching sunset underglow
    float cloudA = sin(vUv.x * 5.8 + vUv.y * 2.4) * 0.5 + 0.5;
    float cloudB = sin(vUv.x * 11.2 - vUv.y * 3.1 + 1.2) * 0.5 + 0.5;
    float cloudBand = smoothstep(0.30, 0.58, h) * (1.0 - smoothstep(0.58, 0.86, h));
    sky = mix(sky, vec3(0.99, 0.76, 0.56), cloudA * cloudB * cloudBand * 0.28 * uWarmth);

    // Soft distant twilight hillside silhouette at very bottom of window view
    float ridge = 0.09 + 0.025 * sin(vUv.x * 4.5 + 0.8) + 0.014 * sin(vUv.x * 9.5);
    float hillMask = 1.0 - smoothstep(ridge - 0.012, ridge + 0.012, h);
    sky = mix(sky, vec3(0.34, 0.27, 0.25), hillMask * 0.78);

    gl_FragColor = vec4(sky, 1.0);
  }
`;

/** Volumetric soft golden sunbeam shader streaming diagonally from the right window */
const SUNBEAM_VERT = /* glsl */ `
  varying vec2 vUv;
  void main() {
    vUv = uv;
    gl_Position = projectionMatrix * modelViewMatrix * vec4(position, 1.0);
  }
`;

const SUNBEAM_FRAG = /* glsl */ `
  uniform float uIntensity;
  varying vec2 vUv;
  void main() {
    float edgeY = smoothstep(0.0, 0.28, vUv.y) * smoothstep(1.0, 0.72, vUv.y);
    float decayX = smoothstep(0.0, 0.85, vUv.x) * (1.0 - smoothstep(0.92, 1.0, vUv.x));
    float rib = 0.76 + 0.24 * sin(vUv.y * 16.0);
    float alpha = edgeY * decayX * rib * uIntensity * 0.22;
    vec3 gold = vec3(1.0, 0.77, 0.45);
    gl_FragColor = vec4(gold, alpha);
  }
`;

function createRoundedRectShape(w: number, h: number, r: number): THREE.Shape {
  const s = new THREE.Shape();
  const hw = w / 2;
  const hh = h / 2;
  const rad = Math.min(r, hw, hh);
  s.moveTo(-hw + rad, -hh);
  s.lineTo(hw - rad, -hh);
  s.quadraticCurveTo(hw, -hh, hw, -hh + rad);
  s.lineTo(hw, hh - rad);
  s.quadraticCurveTo(hw, hh, hw - rad, hh);
  s.lineTo(-hw + rad, hh);
  s.quadraticCurveTo(-hw, hh, -hw, hh - rad);
  s.lineTo(-hw, -hh + rad);
  s.quadraticCurveTo(-hw, -hh, -hw + rad, -hh);
  return s;
}

function createPleatedCurtainGeometry(
  spanZ: number,
  heightY: number,
  pleats: number,
  pleatDepth: number
): THREE.BufferGeometry {
  const segZ = pleats * 6;
  const segY = 10;
  const geom = new THREE.PlaneGeometry(spanZ, heightY, segZ, segY);
  geom.rotateY(-Math.PI / 2);

  const pos = geom.attributes.position as THREE.BufferAttribute;
  for (let i = 0; i < pos.count; i++) {
    const y = pos.getY(i);
    const z = pos.getZ(i);
    const tZ = (z + spanZ / 2) / spanZ;
    const tY = (heightY / 2 - y) / heightY;
    const wave = Math.sin(tZ * Math.PI * 2 * pleats);
    const drapeAmp = pleatDepth * (0.62 + tY * 0.5);
    pos.setX(i, pos.getX(i) + wave * drapeAmp);
  }
  geom.computeVertexNormals();
  return geom;
}

/** Architectural Warm Oak Acoustic Slat Wall (16 vertical oak slats in a single InstancedMesh draw call) */
function OakAcousticSlatWall({ oakMap }: { oakMap: THREE.CanvasTexture }) {
  const meshRef = useRef<THREE.InstancedMesh>(null);
  const count = 16;

  useEffect(() => {
    const inst = meshRef.current;
    if (!inst) return;
    const dummy = new THREE.Object3D();
    for (let i = 0; i < count; i++) {
      const x = -2.62 + i * 0.088;
      dummy.position.set(x, 1.38, -1.205);
      dummy.updateMatrix();
      inst.setMatrixAt(i, dummy.matrix);
    }
    inst.instanceMatrix.needsUpdate = true;
  }, []);

  return (
    <group>
      {/* Dark warm charcoal acoustic felt backing behind the oak slats */}
      <mesh position={[-1.96, 1.38, -1.232]} receiveShadow>
        <planeGeometry args={[1.48, 2.74]} />
        <meshStandardMaterial color="#3c342d" roughness={0.95} />
      </mesh>
      <instancedMesh ref={meshRef} args={[undefined, undefined, count]} castShadow receiveShadow>
        <boxGeometry args={[0.046, 2.74, 0.032]} />
        <meshStandardMaterial map={oakMap} color="#d6b488" roughness={0.56} metalness={0.02} />
      </instancedMesh>
    </group>
  );
}

interface AlbumFrameItem {
  url: string;
  position: [number, number, number];
  title: string;
}

/** Load an image cleanly into a CanvasTexture so WebP decoding & sRGB upload never render black */
function loadDecodedTexture(
  url: string,
  onDone: (tex: THREE.CanvasTexture) => void
): () => void {
  let cancelled = false;
  const img = new Image();
  img.crossOrigin = 'anonymous';
  img.onload = () => {
    if (cancelled) return;
    const canvas = document.createElement('canvas');
    canvas.width = img.naturalWidth || 512;
    canvas.height = img.naturalHeight || 512;
    const ctx = canvas.getContext('2d');
    if (ctx) {
      ctx.drawImage(img, 0, 0, canvas.width, canvas.height);
    }
    const tex = new THREE.CanvasTexture(canvas);
    tex.colorSpace = THREE.SRGBColorSpace;
    tex.anisotropy = 8;
    tex.needsUpdate = true;
    onDone(tex);
  };
  img.src = url;
  return () => {
    cancelled = true;
  };
}

/** Museum-grade Natural Oak Framed 2026 Album Cover Gallery Wall (4 curated albums) */
function AlbumsGalleryWall({
  oakMap,
  onLoaded,
}: {
  oakMap: THREE.CanvasTexture;
  onLoaded: () => void;
}) {
  const frames: AlbumFrameItem[] = useMemo(
    () => [
      { url: './media/albums/lux.webp', position: [1.06, 2.02, -1.215], title: 'LUX' },
      { url: './media/albums/ashe.webp', position: [1.56, 2.02, -1.215], title: 'The Girl Of Your Dreams' },
      { url: './media/albums/raye.webp', position: [1.06, 1.50, -1.215], title: 'THIS MUSIC MAY CONTAIN HOPE.' },
      { url: './media/albums/olivia.webp', position: [1.56, 1.50, -1.215], title: 'you seem pretty sad for a girl so in love' },
    ],
    []
  );

  const [textures, setTextures] = useState<Array<THREE.CanvasTexture | null>>([
    null,
    null,
    null,
    null,
  ]);
  const onLoadedRef = useRef(onLoaded);
  onLoadedRef.current = onLoaded;

  useEffect(() => {
    const loaded: Array<THREE.CanvasTexture | null> = [null, null, null, null];
    const cancels = frames.map((item, idx) =>
      loadDecodedTexture(item.url, (tex) => {
        loaded[idx] = tex;
        setTextures([...loaded]);
        onLoadedRef.current();
      })
    );
    return () => {
      cancels.forEach((c) => c());
      loaded.forEach((t) => t?.dispose());
    };
  }, [frames]);

  const outerSize = 0.43;
  const railThick = 0.022;
  const frameDepth = 0.028;
  const artSize = 0.315;

  return (
    <group>
      {frames.map((item, idx) => {
        const tex = textures[idx];
        return (
          <group key={item.title} position={item.position}>
            {/* Recessed solid backing casting crisp golden sunset shadow onto plaster wall */}
            <mesh position={[0, 0, 0.002]} castShadow receiveShadow>
              <boxGeometry args={[outerSize - 0.01, outerSize - 0.01, 0.012]} />
              <meshStandardMaterial color="#f6f1e8" roughness={0.85} />
            </mesh>

            {/* 4 mitered solid European White Oak outer frame rails */}
            <mesh position={[0, outerSize / 2 - railThick / 2, frameDepth / 2]} castShadow receiveShadow>
              <boxGeometry args={[outerSize, railThick, frameDepth]} />
              <meshStandardMaterial map={oakMap} color="#c9a374" roughness={0.48} />
            </mesh>
            <mesh position={[0, -outerSize / 2 + railThick / 2, frameDepth / 2]} castShadow receiveShadow>
              <boxGeometry args={[outerSize, railThick, frameDepth]} />
              <meshStandardMaterial map={oakMap} color="#c9a374" roughness={0.48} />
            </mesh>
            <mesh position={[-outerSize / 2 + railThick / 2, 0, frameDepth / 2]} castShadow receiveShadow>
              <boxGeometry args={[railThick, outerSize - railThick * 2, frameDepth]} />
              <meshStandardMaterial map={oakMap} color="#c9a374" roughness={0.48} />
            </mesh>
            <mesh position={[outerSize / 2 - railThick / 2, 0, frameDepth / 2]} castShadow receiveShadow>
              <boxGeometry args={[railThick, outerSize - railThick * 2, frameDepth]} />
              <meshStandardMaterial map={oakMap} color="#c9a374" roughness={0.48} />
            </mesh>

            {/* Archival warm off-white museum mat board */}
            <mesh position={[0, 0, 0.012]} receiveShadow>
              <planeGeometry args={[outerSize - railThick * 2, outerSize - railThick * 2]} />
              <meshStandardMaterial color="#f7f3eb" roughness={0.88} />
            </mesh>

            {/* Crisp 2026 Album Cover Print (keyed by loaded state so Three.js always compiles USE_MAP) */}
            <mesh position={[0, 0, 0.0155]} receiveShadow>
              <planeGeometry args={[artSize, artSize]} />
              {tex ? (
                <meshStandardMaterial
                  key="art-loaded"
                  map={tex}
                  emissiveMap={tex}
                  emissive="#ffffff"
                  emissiveIntensity={0.08}
                  roughness={0.58}
                  metalness={0.0}
                />
              ) : (
                <meshStandardMaterial key="art-placeholder" color="#e4dbcd" roughness={0.8} />
              )}
            </mesh>

            {/* Subtle clear anti-reflective gallery glass sheen */}
            <mesh position={[0, 0, 0.024]}>
              <planeGeometry args={[outerSize - railThick * 2, outerSize - railThick * 2]} />
              <meshStandardMaterial
                color="#fffaf2"
                transparent
                opacity={0.06}
                roughness={0.08}
                metalness={0.14}
                depthWrite={false}
              />
            </mesh>
          </group>
        );
      })}
    </group>
  );
}

/** Procedural warm neutral RoomEnvironment PMREM */
function WarmStudioEnvironment() {
  const { gl, scene } = useThree();

  useEffect(() => {
    const pmrem = new THREE.PMREMGenerator(gl);
    const envScene = new RoomEnvironment();
    const envRT = pmrem.fromScene(envScene, 0.045);
    scene.environment = envRT.texture;
    scene.environmentIntensity = 0.32;
    return () => {
      scene.environment = null;
      envRT.dispose();
      envScene.dispose();
      pmrem.dispose();
    };
  }, [gl, scene]);

  return null;
}

function AdaptivePerformanceScaler({ onDprChange }: { onDprChange: (dpr: number) => void }) {
  const frames = useRef(0);
  const accum = useRef(0);
  const currentDpr = useRef(1.5);

  useFrame((_, delta) => {
    frames.current += 1;
    accum.current += delta;
    if (frames.current >= 30) {
      const avgMs = (accum.current / frames.current) * 1000;
      if (avgMs > 28 && currentDpr.current > 1) {
        currentDpr.current = Math.max(1, Number((currentDpr.current - 0.25).toFixed(2)));
        onDprChange(currentDpr.current);
      }
      frames.current = 0;
      accum.current = 0;
    }
  });

  return null;
}

/**
 * Interactive Camera Rig:
 * - Overview: balanced unobstructed golden-hour room framing Oak Slat Wall, Wall AC, Blue M4 iMac,
 *   4 Framed 2026 Album Covers, Apple Store Oak Table, Mi Desk Lamp, Ceiling Light & Sunset Curtains.
 * - Focus iMac: glides right up over the oak desk so the complete Blue iMac + wool-felt desk mat +
 *   keyboard + light bar + lamp arm + framed art edge sit cleanly beside the Liquid Glass popover!
 */
function StudyCameraRig({ reducedMotion }: { reducedMotion: boolean }) {
  const { camera, gl, invalidate } = useThree();
  const controlsRef = useRef<ThreeOrbitControls | null>(null);
  const pointer = useRef({ x: 0, y: 0 });

  const overviewPos = useMemo(() => new THREE.Vector3(0.12, 1.56, 5.06), []);
  const overviewTarget = useMemo(() => new THREE.Vector3(0.06, 1.10, -0.26), []);

  const focusPos = useMemo(() => new THREE.Vector3(0.38, 1.24, 2.52), []);
  const focusTarget = useMemo(() => new THREE.Vector3(0.34, 1.07, -0.28), []);

  const desiredPos = useMemo(() => new THREE.Vector3(), []);
  const desiredTarget = useMemo(() => new THREE.Vector3(), []);
  const prevFocus = useRef<'overview' | 'imac'>('overview');

  useEffect(() => {
    const controls = new ThreeOrbitControls(camera, gl.domElement);
    controls.enableZoom = false;
    controls.enablePan = false;
    controls.enableDamping = true;
    controls.dampingFactor = 0.06;
    controls.rotateSpeed = 0.42;
    controls.minAzimuthAngle = -0.34;
    controls.maxAzimuthAngle = 0.34;
    controls.minPolarAngle = 1.12;
    controls.maxPolarAngle = 1.60;
    controls.target.copy(overviewTarget);
    controls.update();
    controlsRef.current = controls;

    const onControlChange = () => invalidate();
    controls.addEventListener('change', onControlChange);

    const onMove = (e: PointerEvent) => {
      pointer.current.x = (e.clientX / window.innerWidth) * 2 - 1;
      pointer.current.y = -(e.clientY / window.innerHeight) * 2 + 1;
      invalidate();
    };
    window.addEventListener('pointermove', onMove, { passive: true });
    const unsub = useHomeStore.subscribe(() => invalidate());

    return () => {
      unsub();
      controls.removeEventListener('change', onControlChange);
      window.removeEventListener('pointermove', onMove);
      controls.dispose();
    };
  }, [camera, gl, invalidate, overviewTarget]);

  useFrame((_, rawDelta) => {
    const delta = Math.min(rawDelta, 0.05);
    const { cameraFocus, scrollProgress } = useHomeStore.getState();
    const controls = controlsRef.current;
    if (!controls) return;

    const isFocused = cameraFocus === 'imac';
    controls.enabled = !isFocused;

    const px = reducedMotion ? 0 : pointer.current.x;
    const py = reducedMotion ? 0 : pointer.current.y;

    if (isFocused) {
      desiredPos.set(focusPos.x + px * 0.09, focusPos.y + py * 0.05, focusPos.z);
      desiredTarget.set(focusTarget.x + px * 0.03, focusTarget.y + py * 0.02, focusTarget.z);
      const speed = reducedMotion ? 16 : 4.8;
      camera.position.x = THREE.MathUtils.damp(camera.position.x, desiredPos.x, speed, delta);
      camera.position.y = THREE.MathUtils.damp(camera.position.y, desiredPos.y, speed, delta);
      camera.position.z = THREE.MathUtils.damp(camera.position.z, desiredPos.z, speed, delta);

      controls.target.x = THREE.MathUtils.damp(controls.target.x, desiredTarget.x, speed, delta);
      controls.target.y = THREE.MathUtils.damp(controls.target.y, desiredTarget.y, speed, delta);
      controls.target.z = THREE.MathUtils.damp(controls.target.z, desiredTarget.z, speed, delta);
      controls.update();

      if (
        camera.position.distanceTo(desiredPos) > 0.004 ||
        controls.target.distanceTo(desiredTarget) > 0.004
      ) {
        invalidate();
      }
    } else {
      desiredTarget.set(
        overviewTarget.x + px * 0.14,
        overviewTarget.y + py * 0.07 - scrollProgress * 0.1,
        overviewTarget.z
      );
      desiredPos.set(overviewPos.x + px * 0.16, overviewPos.y + py * 0.06, overviewPos.z);

      const distFromBase = camera.position.distanceTo(desiredPos);
      if (distFromBase > 0.01 && prevFocus.current === 'imac') {
        const speed = reducedMotion ? 16 : 4.6;
        camera.position.x = THREE.MathUtils.damp(camera.position.x, desiredPos.x, speed, delta);
        camera.position.y = THREE.MathUtils.damp(camera.position.y, desiredPos.y, speed, delta);
        camera.position.z = THREE.MathUtils.damp(camera.position.z, desiredPos.z, speed, delta);
        if (camera.position.distanceTo(desiredPos) < 0.06) {
          prevFocus.current = 'overview';
        }
        invalidate();
      } else {
        camera.position.z = THREE.MathUtils.damp(camera.position.z, overviewPos.z, 3.2, delta);
        camera.position.y = THREE.MathUtils.damp(camera.position.y, overviewPos.y + py * 0.06, 3.2, delta);
      }

      controls.target.x = THREE.MathUtils.damp(controls.target.x, desiredTarget.x, 4.0, delta);
      controls.target.y = THREE.MathUtils.damp(controls.target.y, desiredTarget.y, 4.0, delta);
      controls.target.z = THREE.MathUtils.damp(controls.target.z, desiredTarget.z, 4.0, delta);
      controls.update();

      if (
        controls.target.distanceTo(desiredTarget) > 0.004 ||
        Math.abs(camera.position.z - overviewPos.z) > 0.005
      ) {
        invalidate();
      }
    }

    if (isFocused) {
      prevFocus.current = 'imac';
    }
  });

  return null;
}

function GoldenHourStudyContent({ onReady }: { onReady: () => void }) {
  const { invalidate } = useThree();

  const sunsetDirRef = useRef<THREE.DirectionalLight>(null);
  const lampSpotRef = useRef<THREE.SpotLight>(null);
  const lampTargetObj = useMemo(() => {
    const obj = new THREE.Object3D();
    obj.position.set(-0.68, 0.72, -0.02);
    return obj;
  }, []);
  const lampDiffuserMatRef = useRef<THREE.MeshStandardMaterial>(null);

  const ceilingPointRef = useRef<THREE.PointLight>(null);
  const ceilingDomeMatRef = useRef<THREE.MeshStandardMaterial>(null);

  const lightBarPointRef = useRef<THREE.PointLight>(null);
  const lightBarLensMatRef = useRef<THREE.MeshStandardMaterial>(null);

  const hemiLightRef = useRef<THREE.HemisphereLight>(null);

  const curtainBackRef = useRef<THREE.Mesh>(null);
  const curtainFrontRef = useRef<THREE.Mesh>(null);
  const curtainMotorRef = useRef<THREE.Group>(null);
  const sunPatchDeskMatRef = useRef<THREE.MeshBasicMaterial>(null);
  const sunPatchWallMatRef = useRef<THREE.MeshBasicMaterial>(null);
  const sunPatchDeskRef = useRef<THREE.Mesh>(null);
  const sunPatchWallRef = useRef<THREE.Mesh>(null);

  const acLouverRef = useRef<THREE.Mesh>(null);
  const acLedCanvas = useMemo(() => {
    const c = document.createElement('canvas');
    c.width = 256;
    c.height = 96;
    drawAcDisplayCanvas(c, false, 26);
    return c;
  }, []);
  const acLedTexture = useMemo(() => {
    const t = new THREE.CanvasTexture(acLedCanvas);
    t.colorSpace = THREE.SRGBColorSpace;
    return t;
  }, [acLedCanvas]);

  const monolithKnobRef = useRef<THREE.Mesh>(null);
  const monolithTrackMatRef = useRef<THREE.MeshStandardMaterial>(null);
  const monolithHaloMatRef = useRef<THREE.MeshBasicMaterial>(null);
  const plugLedMatRef = useRef<THREE.MeshStandardMaterial>(null);

  const animRef = useRef({
    lampIntensity: 4.5,
    ceilingIntensity: 2.2,
    lightBarIntensity: 1.8,
    curtainOpen: 76,
    acLouverAngle: 0.0,
    knobX: 0.055,
  });

  // Procedural high-craft PBR textures
  const oak = useMemo(() => createAppleOakTextures(), []);
  const floorOak = useMemo(() => createHardwoodFloorTextures(), []);
  const feltMatTex = useMemo(() => createFeltMatTexture(), []);
  const rugTex = useMemo(() => createBoucleRugTexture(), []);
  const plasterTex = useMemo(() => createWarmPlasterTexture(), []);
  const linenTex = useMemo(() => createLinenFabricTexture(), []);
  const vinylTex = useMemo(() => createVinylDiscTexture(), []);
  const keyboardTex = useMemo(() => createKeyboardTexture(), []);
  const climateTex = useMemo(() => createClimatePuckTexture(), []);
  const sunPatchTex = useMemo(() => createSunPatchTexture(), []);
  const amberHaloTex = useMemo(() => createAmberHaloTexture(), []);
  const contactShadowTex = useMemo(() => createContactShadowTexture(), []);

  // Load LUX cover cleanly into CanvasTexture for the leaning shelf vinyl sleeve
  const [shelfAlbumTex, setShelfAlbumTex] = useState<THREE.CanvasTexture | null>(null);
  useEffect(() => {
    let texRef: THREE.CanvasTexture | null = null;
    const cancel = loadDecodedTexture('./media/albums/lux.webp', (tex) => {
      texRef = tex;
      setShelfAlbumTex(tex);
      invalidate();
    });
    return () => {
      cancel();
      texRef?.dispose();
    };
  }, [invalidate]);

  // Custom procedural geometries
  const iMacBodyGeo = useMemo(() => {
    const shape = createRoundedRectShape(1.24, 0.85, 0.022);
    const geo = new THREE.ExtrudeGeometry(shape, {
      depth: 0.016,
      bevelEnabled: true,
      bevelThickness: 0.003,
      bevelSize: 0.003,
      bevelSegments: 3,
    });
    geo.center();
    return geo;
  }, []);

  const iMacStandLegGeo = useMemo(() => {
    // Sleek L-shaped anodized blue aluminum stand cleanly BEHIND the chin (+X -> -Z after rotateY(+PI/2))
    const s = new THREE.Shape();
    s.moveTo(-0.055, 0.0);
    s.lineTo(0.11, 0.0);
    s.lineTo(0.11, 0.012);
    s.lineTo(0.088, 0.014);
    s.lineTo(0.058, 0.36);
    s.lineTo(0.042, 0.36);
    s.lineTo(0.068, 0.012);
    s.lineTo(-0.055, 0.011);
    s.closePath();
    const geo = new THREE.ExtrudeGeometry(s, {
      depth: 0.25,
      bevelEnabled: true,
      bevelThickness: 0.0025,
      bevelSize: 0.0025,
      bevelSegments: 2,
    });
    geo.rotateY(Math.PI / 2);
    geo.translate(-0.125, 0, 0);
    return geo;
  }, []);

  const lampBaseGeo = useMemo(() => {
    const pts = [
      new THREE.Vector2(0, 0),
      new THREE.Vector2(0.132, 0),
      new THREE.Vector2(0.132, 0.018),
      new THREE.Vector2(0.122, 0.026),
      new THREE.Vector2(0.0, 0.026),
    ];
    return new THREE.LatheGeometry(pts, 40);
  }, []);

  const acBodyGeo = useMemo(() => {
    const s = createRoundedRectShape(0.22, 0.29, 0.055);
    const geo = new THREE.ExtrudeGeometry(s, {
      depth: 1.04,
      bevelEnabled: true,
      bevelThickness: 0.012,
      bevelSize: 0.012,
      bevelSegments: 3,
    });
    geo.rotateY(Math.PI / 2);
    geo.center();
    return geo;
  }, []);

  const curtainPanelGeo = useMemo(() => createPleatedCurtainGeometry(1.06, 2.54, 12, 0.045), []);
  const sheerPanelGeo = useMemo(() => createPleatedCurtainGeometry(2.18, 2.52, 22, 0.022), []);

  const monolithHouseGeo = useMemo(() => {
    const s = new THREE.Shape();
    s.moveTo(-0.165, -0.145);
    s.lineTo(0.165, -0.145);
    s.lineTo(0.165, 0.04);
    s.lineTo(0.0, 0.205);
    s.lineTo(-0.165, 0.04);
    s.closePath();
    const geo = new THREE.ExtrudeGeometry(s, {
      depth: 0.064,
      bevelEnabled: true,
      bevelThickness: 0.012,
      bevelSize: 0.012,
      bevelSegments: 3,
    });
    geo.center();
    return geo;
  }, []);

  const mugGeo = useMemo(() => {
    const pts = [
      new THREE.Vector2(0, 0),
      new THREE.Vector2(0.036, 0),
      new THREE.Vector2(0.046, 0.045),
      new THREE.Vector2(0.047, 0.088),
      new THREE.Vector2(0.043, 0.092),
      new THREE.Vector2(0.039, 0.086),
      new THREE.Vector2(0.035, 0.012),
      new THREE.Vector2(0, 0.012),
    ];
    return new THREE.LatheGeometry(pts, 32);
  }, []);

  const planterGeo = useMemo(() => {
    // Sculpted organic rounded terracotta vessel profile
    const pts = [
      new THREE.Vector2(0, 0),
      new THREE.Vector2(0.068, 0),
      new THREE.Vector2(0.096, 0.06),
      new THREE.Vector2(0.092, 0.135),
      new THREE.Vector2(0.074, 0.172),
      new THREE.Vector2(0.066, 0.172),
      new THREE.Vector2(0.066, 0.152),
      new THREE.Vector2(0, 0.152),
    ];
    return new THREE.LatheGeometry(pts, 32);
  }, []);

  const sunsetSkyMat = useMemo(
    () =>
      new THREE.ShaderMaterial({
        uniforms: {
          uWarmth: { value: 1.0 },
          uSunReveal: { value: 0.76 },
        },
        vertexShader: SUNSET_SKY_VERT,
        fragmentShader: SUNSET_SKY_FRAG,
      }),
    []
  );

  const sunbeamMat = useMemo(
    () =>
      new THREE.ShaderMaterial({
        uniforms: { uIntensity: { value: 0.76 } },
        vertexShader: SUNBEAM_VERT,
        fragmentShader: SUNBEAM_FRAG,
        transparent: true,
        depthWrite: false,
        blending: THREE.AdditiveBlending,
        side: THREE.DoubleSide,
      }),
    []
  );

  // Live 1280x720 Blue iMac macOS CanvasTexture
  const iMacCanvas = useMemo(() => {
    const c = document.createElement('canvas');
    c.width = 1280;
    c.height = 720;
    const s = useHomeStore.getState();
    drawIMacDisplayCanvas(c, {
      lampOn: s.lampOn,
      lampBrightness: s.lampBrightness,
      lampKelvin: s.lampKelvin,
      ceilingOn: s.ceilingOn,
      ceilingBrightness: s.ceilingBrightness,
      ceilingKelvin: s.ceilingKelvin,
      lightBarOn: s.lightBarOn,
      curtainOpen: s.curtainOpen,
      acOn: s.acOn,
      acTemp: s.acTemp,
      plugOn: s.plugOn,
      pipPinned: s.pipPinned,
      searchQuery: s.searchQuery,
      focused: s.cameraFocus === 'imac',
    });
    return c;
  }, []);

  const iMacTexture = useMemo(() => {
    const t = new THREE.CanvasTexture(iMacCanvas);
    t.colorSpace = THREE.SRGBColorSpace;
    t.anisotropy = 8;
    return t;
  }, [iMacCanvas]);

  useEffect(() => {
    let prevKey = '';
    let prevAcKey = '';
    const unsub = useHomeStore.subscribe((s) => {
      const key = `${s.lampOn}|${s.lampBrightness}|${s.lampKelvin}|${s.ceilingOn}|${s.ceilingBrightness}|${s.ceilingKelvin}|${s.lightBarOn}|${s.curtainOpen}|${s.acOn}|${s.acTemp}|${s.plugOn}|${s.pipPinned}|${s.searchQuery}|${s.cameraFocus}`;
      if (key !== prevKey) {
        prevKey = key;
        drawIMacDisplayCanvas(iMacCanvas, {
          lampOn: s.lampOn,
          lampBrightness: s.lampBrightness,
          lampKelvin: s.lampKelvin,
          ceilingOn: s.ceilingOn,
          ceilingBrightness: s.ceilingBrightness,
          ceilingKelvin: s.ceilingKelvin,
          lightBarOn: s.lightBarOn,
          curtainOpen: s.curtainOpen,
          acOn: s.acOn,
          acTemp: s.acTemp,
          plugOn: s.plugOn,
          pipPinned: s.pipPinned,
          searchQuery: s.searchQuery,
          focused: s.cameraFocus === 'imac',
        });
        iMacTexture.needsUpdate = true;
      }

      const acKey = `${s.acOn}|${s.acTemp}`;
      if (acKey !== prevAcKey) {
        prevAcKey = acKey;
        drawAcDisplayCanvas(acLedCanvas, s.acOn, s.acTemp);
        acLedTexture.needsUpdate = true;
      }
      invalidate();
    });
    return unsub;
  }, [iMacCanvas, iMacTexture, acLedCanvas, acLedTexture, invalidate]);

  useEffect(() => {
    onReady();
    return () => {
      oak.map.dispose();
      oak.roughnessMap.dispose();
      oak.bumpMap.dispose();
      floorOak.map.dispose();
      floorOak.roughnessMap.dispose();
      feltMatTex.dispose();
      rugTex.dispose();
      plasterTex.dispose();
      linenTex.dispose();
      vinylTex.dispose();
      keyboardTex.dispose();
      climateTex.dispose();
      sunPatchTex.dispose();
      amberHaloTex.dispose();
      contactShadowTex.dispose();
      iMacTexture.dispose();
      acLedTexture.dispose();
      iMacBodyGeo.dispose();
      iMacStandLegGeo.dispose();
      lampBaseGeo.dispose();
      acBodyGeo.dispose();
      curtainPanelGeo.dispose();
      sheerPanelGeo.dispose();
      monolithHouseGeo.dispose();
      mugGeo.dispose();
      planterGeo.dispose();
      sunsetSkyMat.dispose();
      sunbeamMat.dispose();
    };
  }, [
    onReady,
    oak,
    floorOak,
    feltMatTex,
    rugTex,
    plasterTex,
    linenTex,
    vinylTex,
    keyboardTex,
    climateTex,
    sunPatchTex,
    amberHaloTex,
    contactShadowTex,
    iMacTexture,
    acLedTexture,
    iMacBodyGeo,
    iMacStandLegGeo,
    lampBaseGeo,
    acBodyGeo,
    curtainPanelGeo,
    sheerPanelGeo,
    monolithHouseGeo,
    mugGeo,
    planterGeo,
    sunsetSkyMat,
    sunbeamMat,
  ]);

  const tmpLampColor = useMemo(() => new THREE.Color(), []);
  const tmpCeilingColor = useMemo(() => new THREE.Color(), []);

  useFrame((_, rawDelta) => {
    const delta = Math.min(rawDelta, 0.05);
    const s = useHomeStore.getState();
    const anim = animRef.current;

    // 1. Mi Desk Lamp 1S
    const targetLamp = s.lampOn ? (s.lampBrightness / 100) * 8.8 : 0;
    anim.lampIntensity = THREE.MathUtils.damp(anim.lampIntensity, targetLamp, 7.5, delta);
    tmpLampColor.set(kelvinToHex(s.lampKelvin));
    if (lampSpotRef.current) {
      lampSpotRef.current.intensity = anim.lampIntensity;
      lampSpotRef.current.color.lerp(tmpLampColor, 0.2);
    }
    if (lampDiffuserMatRef.current) {
      lampDiffuserMatRef.current.emissive.copy(tmpLampColor);
      lampDiffuserMatRef.current.emissiveIntensity = s.lampOn
        ? 0.6 + (s.lampBrightness / 100) * 2.1
        : 0.02;
    }

    // 2. Mi Flush-Mount Ceiling Light (brightness + Kelvin)
    const targetCeiling = s.ceilingOn ? (s.ceilingBrightness / 100) * 4.2 : 0;
    anim.ceilingIntensity = THREE.MathUtils.damp(anim.ceilingIntensity, targetCeiling, 6.5, delta);
    tmpCeilingColor.set(kelvinToHex(s.ceilingKelvin));
    if (ceilingPointRef.current) {
      ceilingPointRef.current.intensity = anim.ceilingIntensity;
      ceilingPointRef.current.color.lerp(tmpCeilingColor, 0.18);
    }
    if (ceilingDomeMatRef.current) {
      ceilingDomeMatRef.current.emissive.copy(tmpCeilingColor);
      ceilingDomeMatRef.current.emissiveIntensity = s.ceilingOn
        ? 0.45 + (s.ceilingBrightness / 100) * 1.4
        : 0.03;
    }

    // 3. Mi Monitor Light Bar
    const targetBar = s.lightBarOn ? 2.2 : 0;
    anim.lightBarIntensity = THREE.MathUtils.damp(anim.lightBarIntensity, targetBar, 8, delta);
    if (lightBarPointRef.current) {
      lightBarPointRef.current.intensity = anim.lightBarIntensity;
    }
    if (lightBarLensMatRef.current) {
      lightBarLensMatRef.current.emissiveIntensity = s.lightBarOn ? 2.2 : 0.02;
    }

    // 4. Motorized Pleated Linen Curtains + Dynamic Golden Sunset Sunbeams & Patches
    anim.curtainOpen = THREE.MathUtils.damp(anim.curtainOpen, s.curtainOpen, 4.6, delta);
    const openRatio = anim.curtainOpen / 100;

    const panelScaleZ = THREE.MathUtils.lerp(1.0, 0.24, openRatio);
    const halfWindowSpan = 1.06;
    const edgeBackZ = -0.14 - halfWindowSpan + (halfWindowSpan * panelScaleZ) / 2;
    const edgeFrontZ = -0.14 + halfWindowSpan - (halfWindowSpan * panelScaleZ) / 2;

    if (curtainBackRef.current) {
      curtainBackRef.current.scale.z = panelScaleZ;
      curtainBackRef.current.position.z = edgeBackZ;
    }
    if (curtainFrontRef.current) {
      curtainFrontRef.current.scale.z = panelScaleZ;
      curtainFrontRef.current.position.z = edgeFrontZ;
    }
    if (curtainMotorRef.current) {
      curtainMotorRef.current.position.z = edgeBackZ + (halfWindowSpan * panelScaleZ) / 2 - 0.04;
    }

    sunsetSkyMat.uniforms.uSunReveal.value = openRatio;
    sunbeamMat.uniforms.uIntensity.value = openRatio;

    if (sunsetDirRef.current) {
      sunsetDirRef.current.intensity = 0.16 + openRatio * 3.05;
    }
    if (sunPatchDeskMatRef.current && sunPatchDeskRef.current) {
      sunPatchDeskMatRef.current.opacity = Math.max(0, openRatio * 0.62);
      sunPatchDeskRef.current.scale.set(0.55 + openRatio * 0.65, 0.72 + openRatio * 0.42, 1);
    }
    if (sunPatchWallMatRef.current && sunPatchWallRef.current) {
      sunPatchWallMatRef.current.opacity = Math.max(0, openRatio * 0.52);
      sunPatchWallRef.current.scale.set(0.45 + openRatio * 0.72, 0.8 + openRatio * 0.28, 1);
    }

    if (hemiLightRef.current) {
      hemiLightRef.current.intensity = 0.30 + openRatio * 0.26 + (anim.ceilingIntensity / 4.2) * 0.32;
    }

    // 5. Mi Wall AC louver
    const targetLouver = s.acOn ? 0.72 : 0.0;
    anim.acLouverAngle = THREE.MathUtils.damp(anim.acLouverAngle, targetLouver, 5.5, delta);
    if (acLouverRef.current) {
      acLouverRef.current.rotation.x = anim.acLouverAngle;
    }

    // 6. Home Switch Monolith
    const targetKnobX = s.monolithOn ? 0.055 : -0.055;
    anim.knobX = THREE.MathUtils.damp(anim.knobX, targetKnobX, 9, delta);
    if (monolithKnobRef.current) {
      monolithKnobRef.current.position.x = anim.knobX;
    }
    if (monolithTrackMatRef.current) {
      monolithTrackMatRef.current.color.set(s.monolithOn ? '#f59e0b' : '#b8afa4');
      monolithTrackMatRef.current.emissive.set(s.monolithOn ? '#d97706' : '#000000');
      monolithTrackMatRef.current.emissiveIntensity = s.monolithOn ? 0.52 : 0;
    }
    if (monolithHaloMatRef.current) {
      monolithHaloMatRef.current.opacity = s.monolithOn ? 0.46 : 0.0;
    }

    // 7. Protected emerald Mi Smart Plug LED
    const flashElapsed = Date.now() - s.plugProtectedFlash;
    const isFlashing = flashElapsed < 1400;
    if (plugLedMatRef.current) {
      plugLedMatRef.current.emissiveIntensity = isFlashing
        ? 1.8 + Math.sin(flashElapsed * 0.022) * 1.1
        : 1.75;
    }

    const stillSettling =
      Math.abs(anim.lampIntensity - targetLamp) > 0.02 ||
      Math.abs(anim.ceilingIntensity - targetCeiling) > 0.02 ||
      Math.abs(anim.lightBarIntensity - targetBar) > 0.02 ||
      Math.abs(anim.curtainOpen - s.curtainOpen) > 0.15 ||
      Math.abs(anim.acLouverAngle - targetLouver) > 0.005 ||
      Math.abs(anim.knobX - targetKnobX) > 0.002 ||
      isFlashing;

    if (stillSettling) {
      invalidate();
    }
  });

  const handleHover = (target: HoverTarget) => {
    useHomeStore.getState().setHoveredTarget(target);
    document.body.style.cursor = target ? 'pointer' : '';
  };

  useEffect(
    () => () => {
      document.body.style.cursor = '';
    },
    []
  );

  return (
    <>
      <color attach="background" args={['#dccbb6']} />
      <fog attach="fog" args={['#e0d1bd', 9.5, 18.5]} />
      <WarmStudioEnvironment />

      {/* Warm golden-hour bounce + subtle cool twilight sky fill from high left for rich color contrast */}
      <hemisphereLight
        ref={hemiLightRef}
        color="#ffe2be"
        groundColor="#8c7155"
        intensity={0.58}
      />
      <directionalLight position={[-3.8, 2.8, 2.2]} color="#9abce4" intensity={0.34} />

      {/* Primary 2048x2048 Golden-Hour Sunset Directional Light streaming low & warm from right window */}
      <directionalLight
        ref={sunsetDirRef}
        position={[4.9, 1.92, 1.0]}
        color="#ff9640"
        intensity={2.5}
        castShadow
        shadow-mapSize-width={2048}
        shadow-mapSize-height={2048}
        shadow-radius={4}
        shadow-bias={-0.0004}
        shadow-normalBias={0.018}
        shadow-camera-left={-3.4}
        shadow-camera-right={3.4}
        shadow-camera-top={3.2}
        shadow-camera-bottom={-1.6}
        shadow-camera-near={0.5}
        shadow-camera-far={12}
      />

      {/* Mi Flush-Mount Ceiling Light PointLight (live brightness + 2700K-6500K Kelvin) */}
      <pointLight
        ref={ceilingPointRef}
        position={[0.0, 2.48, -0.08]}
        color="#ffd29d"
        intensity={2.0}
        distance={8.5}
        decay={1.8}
      />

      {/* Mi LED Desk Lamp 1S SpotLight */}
      <primitive object={lampTargetObj} />
      <spotLight
        ref={lampSpotRef}
        position={[-0.78, 1.24, -0.08]}
        target={lampTargetObj}
        angle={0.86}
        penumbra={0.82}
        distance={4.2}
        decay={2}
        intensity={5.8}
        color="#ffc885"
        castShadow
        shadow-mapSize-width={512}
        shadow-mapSize-height={512}
        shadow-bias={-0.0006}
      />

      {/* Mi Monitor Light Bar asymmetric forward keyboard/oak wash */}
      <pointLight
        ref={lightBarPointRef}
        position={[0.02, 1.15, 0.28]}
        color="#ffe2b5"
        intensity={2.1}
        distance={1.55}
        decay={2.1}
      />

      {/* ==================== Warm Architectural Study Interior ==================== */}
      {/* Back Venetian lime-plaster wall */}
      <mesh position={[0, 1.32, -1.24]} receiveShadow>
        <planeGeometry args={[7.4, 3.8]} />
        <meshStandardMaterial map={plasterTex} roughness={0.93} metalness={0.0} />
      </mesh>

      {/* Left architectural oak acoustic slat feature wall (16 instanced oak slats) */}
      <OakAcousticSlatWall oakMap={oak.map} />

      {/* Crisp European White Oak Baseboard Molding along back & left walls */}
      <mesh position={[0, -0.17, -1.22]} receiveShadow>
        <boxGeometry args={[7.2, 0.11, 0.028]} />
        <meshStandardMaterial map={oak.map} color="#cdb08b" roughness={0.62} />
      </mesh>
      <mesh position={[-2.92, -0.17, 0.4]} rotation={[0, Math.PI / 2, 0]} receiveShadow>
        <boxGeometry args={[4.4, 0.11, 0.028]} />
        <meshStandardMaterial map={oak.map} color="#cdb08b" roughness={0.62} />
      </mesh>

      {/* Subtle architectural ceiling shadow reveal trim */}
      <mesh position={[0, 2.72, -1.21]}>
        <boxGeometry args={[7.2, 0.028, 0.04]} />
        <meshStandardMaterial color="#c9baa4" roughness={0.88} />
      </mesh>

      {/* Left cream plaster return wall */}
      <mesh position={[-2.95, 1.32, 0.4]} rotation={[0, Math.PI / 2, 0]} receiveShadow>
        <planeGeometry args={[4.4, 3.8]} />
        <meshStandardMaterial color="#e0d1bc" roughness={0.94} />
      </mesh>

      {/* Warm cream ceiling plane */}
      <mesh position={[0, 2.74, 0.3]} rotation={[Math.PI / 2, 0, 0]}>
        <planeGeometry args={[7.2, 4.4]} />
        <meshStandardMaterial color="#efe6da" roughness={0.95} />
      </mesh>

      {/* Wide-plank European Oak Hardwood Floor + Woven Oatmeal Bouclé Area Rug */}
      <mesh position={[0, -0.22, 0.4]} rotation={[-Math.PI / 2, 0, 0]} receiveShadow>
        <planeGeometry args={[7.4, 4.6]} />
        <meshStandardMaterial
          map={floorOak.map}
          roughnessMap={floorOak.roughnessMap}
          roughness={0.66}
          metalness={0.02}
        />
      </mesh>
      <mesh position={[0.04, -0.212, 0.28]} rotation={[-Math.PI / 2, 0, 0]} receiveShadow>
        <planeGeometry args={[3.45, 2.05]} />
        <meshStandardMaterial map={rugTex} roughness={0.96} />
      </mesh>

      {/* Curated Gallery Wall: User's 4 "Albums of the Year 2026" in Natural Oak Museum Frames */}
      <AlbumsGalleryWall oakMap={oak.map} onLoaded={invalidate} />

      {/* Projected Golden Sunset Window Light Patch on Back Plaster Wall */}
      <mesh ref={sunPatchWallRef} position={[-0.38, 1.48, -1.226]} rotation={[0, 0, -0.14]}>
        <planeGeometry args={[2.35, 1.55]} />
        <meshBasicMaterial
          ref={sunPatchWallMatRef}
          map={sunPatchTex}
          transparent
          opacity={0.38}
          blending={THREE.AdditiveBlending}
          depthWrite={false}
        />
      </mesh>

      {/* ==================== Apple Store European White Oak Desk ==================== */}
      <group>
        {/* Monolithic thick European White Oak tabletop slab */}
        <mesh position={[0.02, 0.672, -0.02]} castShadow receiveShadow>
          <boxGeometry args={[2.92, 0.096, 1.18]} />
          <meshStandardMaterial
            map={oak.map}
            roughnessMap={oak.roughnessMap}
            bumpMap={oak.bumpMap}
            bumpScale={0.003}
            roughness={0.54}
            metalness={0.02}
          />
        </mesh>

        {/* Seamless mitered thick oak slab legs */}
        <mesh position={[-1.39, 0.21, -0.02]} castShadow receiveShadow>
          <boxGeometry args={[0.096, 0.88, 1.12]} />
          <meshStandardMaterial map={oak.map} roughness={0.58} />
        </mesh>
        <mesh position={[1.43, 0.21, -0.02]} castShadow receiveShadow>
          <boxGeometry args={[0.096, 0.88, 1.12]} />
          <meshStandardMaterial map={oak.map} roughness={0.58} />
        </mesh>

        {/* Flush brushed-aluminum Apple desk power dot */}
        <mesh position={[0.66, 0.721, -0.34]} rotation={[-Math.PI / 2, 0, 0]}>
          <circleGeometry args={[0.028, 24]} />
          <meshStandardMaterial color="#d4cec4" metalness={0.62} roughness={0.3} />
        </mesh>

        {/* Woven Oatmeal Wool-Felt Desk Mat under Magic Keyboard & Magic Mouse */}
        <mesh position={[0.06, 0.722, 0.21]} receiveShadow>
          <boxGeometry args={[0.98, 0.005, 0.36]} />
          <meshStandardMaterial map={feltMatTex} roughness={0.94} />
        </mesh>

        {/* Projected Golden Sunset Light Patch across the Oak Tabletop */}
        <mesh
          ref={sunPatchDeskRef}
          position={[0.42, 0.726, 0.06]}
          rotation={[-Math.PI / 2, 0, -0.22]}
        >
          <planeGeometry args={[2.1, 1.12]} />
          <meshBasicMaterial
            ref={sunPatchDeskMatRef}
            map={sunPatchTex}
            transparent
            opacity={0.44}
            blending={THREE.AdditiveBlending}
            depthWrite={false}
          />
        </mesh>
      </group>

      {/* ==================== Centerpiece: Latest Blue M4 iMac 24" (Click to Focus macOS + Reveal Liquid Glass!) ==================== */}
      <group
        position={[0.02, 0.72, -0.28]}
        onClick={(e) => {
          e.stopPropagation();
          const st = useHomeStore.getState();
          st.toggleCameraFocus();
          playTactileSound('click', st.soundEnabled);
        }}
        onPointerOver={(e) => {
          e.stopPropagation();
          handleHover('imac');
        }}
        onPointerOut={() => handleHover(null)}
      >
        {/* Soft desk contact shadow under aluminum foot */}
        <mesh position={[0, 0.002, 0.02]} rotation={[-Math.PI / 2, 0, 0]}>
          <planeGeometry args={[0.48, 0.42]} />
          <meshBasicMaterial map={contactShadowTex} transparent opacity={0.78} depthWrite={false} />
        </mesh>

        {/* Extruded L-shaped anodized blue aluminum stand cleanly BEHIND chin */}
        <mesh geometry={iMacStandLegGeo} position={[0, 0.0, 0.0]} castShadow receiveShadow>
          <meshStandardMaterial color="#8daec9" metalness={0.76} roughness={0.28} />
        </mesh>

        {/* Display Assembly tilted gently 3.5deg back */}
        <group position={[0, 0.565, 0.0]} rotation={[-0.035, 0, 0]}>
          {/* Deep cobalt-blue anodized rear & perimeter aluminum chassis */}
          <mesh geometry={iMacBodyGeo} castShadow receiveShadow>
            <meshStandardMaterial color="#3d6694" metalness={0.72} roughness={0.28} />
          </mesh>

          {/* Iconic crisp white glass display bezel */}
          <mesh position={[0, 0.068, 0.0145]}>
            <planeGeometry args={[1.224, 0.706]} />
            <meshStandardMaterial color="#f6f5f2" roughness={0.34} metalness={0.02} />
          </mesh>

          {/* Signature Apple M4 Blue pastel powdery-blue lower chin */}
          <mesh position={[0, -0.354, 0.0145]}>
            <planeGeometry args={[1.224, 0.138]} />
            <meshStandardMaterial color="#a0bcd8" roughness={0.3} metalness={0.14} />
          </mesh>

          {/* Subtle FaceTime camera lens */}
          <mesh position={[0, 0.402, 0.0168]}>
            <circleGeometry args={[0.0055, 16]} />
            <meshStandardMaterial color="#1f242c" roughness={0.25} />
          </mesh>

          {/* Live 1280x720 macOS Sequoia Nano-Texture Screen */}
          <mesh position={[0, 0.068, 0.0165]}>
            <planeGeometry args={[1.168, 0.656]} />
            <meshStandardMaterial
              map={iMacTexture}
              emissiveMap={iMacTexture}
              emissive="#ffffff"
              emissiveIntensity={0.62}
              roughness={0.58}
              metalness={0.0}
            />
          </mesh>

          {/* ==================== Mi Computer Monitor Light Bar (Clamped atop Blue iMac) ==================== */}
          <group
            position={[0, 0.435, 0.022]}
            onClick={(e) => {
              e.stopPropagation();
              const st = useHomeStore.getState();
              st.toggleLightBar();
              playTactileSound('click', st.soundEnabled);
            }}
            onPointerOver={(e) => {
              e.stopPropagation();
              handleHover('lightbar');
            }}
            onPointerOut={() => handleHover(null)}
          >
            <mesh rotation={[0, 0, Math.PI / 2]} castShadow>
              <cylinderGeometry args={[0.017, 0.017, 0.64, 24]} />
              <meshStandardMaterial color="#2a2c30" metalness={0.62} roughness={0.34} />
            </mesh>
            {/* Subtle brushed gunmetal end rings */}
            <mesh position={[-0.32, 0, 0]} rotation={[0, 0, Math.PI / 2]}>
              <cylinderGeometry args={[0.0175, 0.0175, 0.012, 24]} />
              <meshStandardMaterial color="#45484f" metalness={0.75} roughness={0.28} />
            </mesh>
            <mesh position={[0.32, 0, 0]} rotation={[0, 0, Math.PI / 2]}>
              <cylinderGeometry args={[0.0175, 0.0175, 0.012, 24]} />
              <meshStandardMaterial color="#45484f" metalness={0.75} roughness={0.28} />
            </mesh>
            {/* Asymmetric warm diffuser strip */}
            <mesh position={[0, -0.014, 0.006]} rotation={[0.38, 0, 0]}>
              <boxGeometry args={[0.58, 0.006, 0.012]} />
              <meshStandardMaterial
                ref={lightBarLensMatRef}
                color="#fff3de"
                emissive="#ffdfa8"
                emissiveIntensity={2.2}
                roughness={0.2}
              />
            </mesh>
            <mesh position={[0, 0.002, -0.036]}>
              <boxGeometry args={[0.08, 0.016, 0.072]} />
              <meshStandardMaterial color="#24262a" metalness={0.5} roughness={0.42} />
            </mesh>
            <mesh position={[0, -0.028, -0.068]} rotation={[0, 0, Math.PI / 2]}>
              <cylinderGeometry args={[0.02, 0.02, 0.14, 18]} />
              <meshStandardMaterial color="#2c2e33" metalness={0.6} roughness={0.35} />
            </mesh>
          </group>
        </group>
      </group>

      {/* ==================== Color-Matched Blue iMac Magic Keyboard, Magic Mouse & Mi Light Bar Wireless Puck ==================== */}
      <group position={[0.02, 0.725, 0.21]}>
        <mesh position={[-0.06, 0.008, 0]} rotation={[0.04, 0, 0]} castShadow receiveShadow>
          <boxGeometry args={[0.52, 0.012, 0.195]} />
          <meshStandardMaterial color="#a9c2dc" metalness={0.62} roughness={0.3} />
        </mesh>
        <mesh position={[-0.06, 0.015, 0]} rotation={[-Math.PI / 2 + 0.04, 0, 0]}>
          <planeGeometry args={[0.505, 0.184]} />
          <meshStandardMaterial map={keyboardTex} roughness={0.42} />
        </mesh>

        {/* Magic Mouse */}
        <group position={[0.32, 0.0, 0.01]}>
          <mesh position={[0, 0.004, 0]} castShadow>
            <cylinderGeometry args={[0.045, 0.043, 0.007, 24]} />
            <meshStandardMaterial color="#a2bdd8" metalness={0.68} roughness={0.28} />
          </mesh>
          <mesh position={[0, 0.008, 0]} scale={[0.92, 0.34, 1.52]} castShadow>
            <sphereGeometry args={[0.045, 24, 14, 0, Math.PI * 2, 0, Math.PI / 2]} />
            <meshStandardMaterial color="#f8f7f5" roughness={0.14} metalness={0.05} />
          </mesh>
        </group>

        {/* Iconic Matte-Black Mi Monitor Light Bar Wireless Rotary Puck Controller */}
        <group
          position={[0.45, 0.0, -0.06]}
          onClick={(e) => {
            e.stopPropagation();
            const st = useHomeStore.getState();
            st.toggleLightBar();
            playTactileSound('click', st.soundEnabled);
          }}
          onPointerOver={(e) => {
            e.stopPropagation();
            handleHover('lightbar');
          }}
          onPointerOut={() => handleHover(null)}
        >
          <mesh position={[0, 0.012, 0]} castShadow receiveShadow>
            <cylinderGeometry args={[0.032, 0.034, 0.024, 28]} />
            <meshStandardMaterial color="#25272b" metalness={0.48} roughness={0.38} />
          </mesh>
          <mesh position={[0, 0.0245, 0]} rotation={[-Math.PI / 2, 0, 0]}>
            <ringGeometry args={[0.024, 0.027, 28]} />
            <meshStandardMaterial color="#42454c" metalness={0.7} roughness={0.3} />
          </mesh>
        </group>
      </group>

      {/* ==================== Mi LED Desk Lamp 1S / Pro (Left Oak Desk) ==================== */}
      <group
        position={[-0.96, 0.72, -0.14]}
        rotation={[0, 0.26, 0]}
        onClick={(e) => {
          e.stopPropagation();
          const st = useHomeStore.getState();
          st.toggleLamp();
          playTactileSound('click', st.soundEnabled);
        }}
        onPointerOver={(e) => {
          e.stopPropagation();
          handleHover('lamp');
        }}
        onPointerOut={() => handleHover(null)}
      >
        <mesh position={[0, 0.002, 0]} rotation={[-Math.PI / 2, 0, 0]}>
          <planeGeometry args={[0.36, 0.36]} />
          <meshBasicMaterial map={contactShadowTex} transparent opacity={0.74} depthWrite={false} />
        </mesh>

        <mesh geometry={lampBaseGeo} castShadow receiveShadow>
          <meshStandardMaterial color="#f4f2ee" roughness={0.34} metalness={0.06} />
        </mesh>

        {/* Knurled brushed tactile rotary dimmer dial */}
        <mesh position={[0.055, 0.032, 0.04]} castShadow>
          <cylinderGeometry args={[0.02, 0.021, 0.014, 24]} />
          <meshStandardMaterial color="#e8e5df" metalness={0.3} roughness={0.3} />
        </mesh>
        <mesh position={[0.055, 0.04, 0.04]} rotation={[-Math.PI / 2, 0, 0]}>
          <ringGeometry args={[0.017, 0.0195, 24]} />
          <meshStandardMaterial color="#cfc9be" metalness={0.6} roughness={0.28} />
        </mesh>

        {/* Slender matte-white aluminum vertical stem */}
        <mesh position={[-0.042, 0.285, -0.02]} castShadow>
          <cylinderGeometry args={[0.011, 0.011, 0.54, 20]} />
          <meshStandardMaterial color="#f5f3ef" roughness={0.32} metalness={0.14} />
        </mesh>

        {/* Iconic Mi orange-red flexible hinge cable accent */}
        <mesh position={[-0.042, 0.562, -0.02]} rotation={[0, 0, -Math.PI / 4]}>
          <torusGeometry args={[0.018, 0.0038, 10, 18, Math.PI * 0.9]} />
          <meshStandardMaterial color="#e0522b" roughness={0.46} />
        </mesh>
        <mesh position={[-0.042, 0.556, -0.02]} rotation={[Math.PI / 2, 0, 0]}>
          <cylinderGeometry args={[0.014, 0.014, 0.024, 20]} />
          <meshStandardMaterial color="#d2cec8" metalness={0.7} roughness={0.28} />
        </mesh>

        {/* Horizontal pill light bar arm + warm acrylic diffuser */}
        <group position={[0.175, 0.562, -0.02]} rotation={[0, 0, -0.04]}>
          <mesh rotation={[0, 0, Math.PI / 2]} castShadow>
            <capsuleGeometry args={[0.013, 0.44, 8, 16]} />
            <meshStandardMaterial color="#f5f3ef" roughness={0.32} metalness={0.12} />
          </mesh>
          <mesh position={[0.02, -0.012, 0]}>
            <boxGeometry args={[0.38, 0.006, 0.016]} />
            <meshStandardMaterial
              ref={lampDiffuserMatRef}
              color="#fff6e6"
              emissive="#ffcc85"
              emissiveIntensity={2.0}
              roughness={0.25}
            />
          </mesh>
        </group>
      </group>

      {/* ==================== Mi Flush-Mount Ceiling Light (Overhead) ==================== */}
      <group
        position={[0.0, 2.71, -0.14]}
        onClick={(e) => {
          e.stopPropagation();
          const st = useHomeStore.getState();
          st.toggleCeiling();
          playTactileSound('click', st.soundEnabled);
        }}
        onPointerOver={(e) => {
          e.stopPropagation();
          handleHover('ceiling');
        }}
        onPointerOut={() => handleHover(null)}
      >
        <mesh>
          <cylinderGeometry args={[0.76, 0.74, 0.055, 48]} />
          <meshStandardMaterial color="#f5f2ec" roughness={0.38} metalness={0.08} />
        </mesh>
        <mesh position={[0, -0.024, 0]} rotation={[Math.PI / 2, 0, 0]}>
          <torusGeometry args={[0.73, 0.008, 12, 48]} />
          <meshStandardMaterial color="#d4cbc0" metalness={0.62} roughness={0.3} />
        </mesh>
        <mesh position={[0, -0.03, 0]}>
          <cylinderGeometry args={[0.71, 0.68, 0.024, 48]} />
          <meshStandardMaterial
            ref={ceilingDomeMatRef}
            color="#fff9f0"
            emissive="#ffd6a3"
            emissiveIntensity={1.15}
            roughness={0.32}
          />
        </mesh>
      </group>

      {/* ==================== Mi Wall-Mounted Minimalist Air Conditioner (Upper Left Wall) ==================== */}
      <group
        position={[-1.68, 2.16, -1.08]}
        onClick={(e) => {
          e.stopPropagation();
          const st = useHomeStore.getState();
          st.toggleAc();
          playTactileSound('click', st.soundEnabled);
        }}
        onPointerOver={(e) => {
          e.stopPropagation();
          handleHover('ac');
        }}
        onPointerOut={() => handleHover(null)}
      >
        <mesh geometry={acBodyGeo} castShadow receiveShadow>
          <meshStandardMaterial color="#f3f1ec" roughness={0.34} metalness={0.05} />
        </mesh>
        <mesh position={[0, 0.015, 0.123]}>
          <planeGeometry args={[0.98, 0.24]} />
          <meshStandardMaterial
            map={acLedTexture}
            emissiveMap={acLedTexture}
            emissive="#b6dcff"
            emissiveIntensity={0.22}
            roughness={0.34}
          />
        </mesh>
        <mesh position={[0, -0.105, 0.095]}>
          <boxGeometry args={[0.92, 0.044, 0.05]} />
          <meshStandardMaterial color="#2c2a27" roughness={0.85} />
        </mesh>
        <mesh ref={acLouverRef} position={[0, -0.12, 0.118]}>
          <boxGeometry args={[0.94, 0.036, 0.014]} />
          <meshStandardMaterial color="#efede8" roughness={0.34} />
        </mesh>
      </group>

      {/* ==================== Tall Sunset Window + Double-Layer Sheer & Motorized Pleated Curtains + Mi Curtain Motor ==================== */}
      <group position={[2.46, 1.32, -0.14]}>
        <mesh position={[0.24, 0, 0]} rotation={[0, -Math.PI / 2, 0]}>
          <planeGeometry args={[2.28, 2.52]} />
          <primitive object={sunsetSkyMat} attach="material" />
        </mesh>

        {/* Architectural warm-bronze window frame & mullions */}
        <mesh position={[0.1, 1.24, 0]}>
          <boxGeometry args={[0.18, 0.06, 2.34]} />
          <meshStandardMaterial color="#463d34" roughness={0.55} metalness={0.28} />
        </mesh>
        <mesh position={[0.1, -1.24, 0]}>
          <boxGeometry args={[0.24, 0.07, 2.38]} />
          <meshStandardMaterial map={oak.map} color="#d6be9c" roughness={0.58} />
        </mesh>
        <mesh position={[0.1, 0, -1.14]}>
          <boxGeometry args={[0.18, 2.52, 0.06]} />
          <meshStandardMaterial color="#463d34" roughness={0.55} metalness={0.28} />
        </mesh>
        <mesh position={[0.1, 0, 1.14]}>
          <boxGeometry args={[0.18, 2.52, 0.06]} />
          <meshStandardMaterial color="#463d34" roughness={0.55} metalness={0.28} />
        </mesh>
        <mesh position={[0.12, 0.14, 0]}>
          <boxGeometry args={[0.04, 0.026, 2.26]} />
          <meshStandardMaterial color="#463d34" roughness={0.5} metalness={0.3} />
        </mesh>
        <mesh position={[0.12, 0, 0]}>
          <boxGeometry args={[0.04, 2.48, 0.026]} />
          <meshStandardMaterial color="#463d34" roughness={0.5} metalness={0.3} />
        </mesh>

        {/* Gossamer translucent warm inner sheer voile curtain diffusing golden-hour glow */}
        <mesh geometry={sheerPanelGeo} position={[0.02, 0.02, 0]}>
          <meshStandardMaterial
            color="#fff6e6"
            emissive="#ffca88"
            emissiveIntensity={0.28}
            transparent
            opacity={0.22}
            roughness={0.92}
            side={THREE.DoubleSide}
            depthWrite={false}
          />
        </mesh>

        {/* Dual ceiling-mounted slim matte-white curtain rail */}
        <mesh position={[-0.08, 1.33, 0]}>
          <boxGeometry args={[0.044, 0.028, 2.34]} />
          <meshStandardMaterial color="#f0ede8" roughness={0.36} metalness={0.25} />
        </mesh>

        {/* Volumetric diagonal Golden Sunset Sunbeams */}
        <mesh position={[-1.25, -0.05, 0.04]} rotation={[0.12, 0.08, 0.38]}>
          <planeGeometry args={[2.8, 1.85]} />
          <primitive object={sunbeamMat} attach="material" />
        </mesh>
        <mesh position={[-1.18, -0.18, -0.34]} rotation={[-0.08, 0.16, 0.34]}>
          <planeGeometry args={[2.5, 1.55]} />
          <primitive object={sunbeamMat} attach="material" />
        </mesh>
      </group>

      {/* Motorized Pleated Linen Curtain Panels + Mi Curtain Motor (米家窗帘伴侣) */}
      <group
        onClick={(e) => {
          e.stopPropagation();
          const st = useHomeStore.getState();
          st.cycleCurtains();
          playTactileSound('click', st.soundEnabled);
        }}
        onPointerOver={(e) => {
          e.stopPropagation();
          handleHover('curtains');
        }}
        onPointerOut={() => handleHover(null)}
      >
        <mesh ref={curtainBackRef} geometry={curtainPanelGeo} position={[2.36, 1.38, -0.78]} castShadow>
          <meshStandardMaterial
            map={linenTex}
            color="#f5ecde"
            emissive="#ffbd73"
            emissiveIntensity={0.22}
            roughness={0.88}
            side={THREE.DoubleSide}
          />
        </mesh>

        <mesh ref={curtainFrontRef} geometry={curtainPanelGeo} position={[2.36, 1.38, 0.5]} castShadow>
          <meshStandardMaterial
            map={linenTex}
            color="#f5ecde"
            emissive="#ffbd73"
            emissiveIntensity={0.22}
            roughness={0.88}
            side={THREE.DoubleSide}
          />
        </mesh>

        {/* Detailed Cylindrical Mi Curtain Motor (米家窗帘伴侣) with top rail gripper & LED */}
        <group ref={curtainMotorRef} position={[2.32, 2.52, -0.45]}>
          <mesh position={[0, 0.085, 0]}>
            <boxGeometry args={[0.044, 0.042, 0.062]} />
            <meshStandardMaterial color="#e6e2da" roughness={0.4} />
          </mesh>
          <mesh castShadow>
            <capsuleGeometry args={[0.032, 0.095, 8, 20]} />
            <meshStandardMaterial color="#f5f3ef" roughness={0.34} metalness={0.06} />
          </mesh>
          <mesh position={[-0.033, 0.015, 0]}>
            <sphereGeometry args={[0.0045, 10, 10]} />
            <meshStandardMaterial color="#22c55e" emissive="#22c55e" emissiveIntensity={1.6} />
          </mesh>
        </group>
      </group>

      {/* ==================== Floating Oak Shelf + Home Switch Monolith + Leaning Vinyl Record & Art Books ==================== */}
      <group position={[-1.12, 1.54, -1.07]}>
        <mesh castShadow receiveShadow>
          <boxGeometry args={[1.08, 0.034, 0.25]} />
          <meshStandardMaterial map={oak.map} roughness={0.56} />
        </mesh>

        {/* AppIcon.svg Homage: Beveled Home Switch Monolith */}
        <group
          position={[0.24, 0.172, 0.01]}
          onClick={(e) => {
            e.stopPropagation();
            const st = useHomeStore.getState();
            st.toggleMonolith();
            playTactileSound(st.monolithOn ? 'relayOn' : 'relayOff', st.soundEnabled);
          }}
          onPointerOver={(e) => {
            e.stopPropagation();
            handleHover('monolith');
          }}
          onPointerOut={() => handleHover(null)}
        >
          <mesh geometry={monolithHouseGeo} castShadow>
            <meshStandardMaterial color="#faf7f2" roughness={0.28} metalness={0.05} />
          </mesh>
          <mesh position={[0, -0.02, 0.046]} rotation={[0, 0, Math.PI / 2]}>
            <capsuleGeometry args={[0.024, 0.095, 8, 16]} />
            <meshStandardMaterial
              ref={monolithTrackMatRef}
              color="#f59e0b"
              emissive="#d97706"
              emissiveIntensity={0.52}
              roughness={0.28}
            />
          </mesh>
          <mesh ref={monolithKnobRef} position={[0.055, -0.02, 0.064]} castShadow>
            <sphereGeometry args={[0.027, 20, 20]} />
            <meshStandardMaterial color="#ffffff" roughness={0.2} metalness={0.06} />
          </mesh>
          <mesh position={[0, 0.02, -0.042]}>
            <planeGeometry args={[0.56, 0.56]} />
            <meshBasicMaterial
              ref={monolithHaloMatRef}
              map={amberHaloTex}
              transparent
              opacity={0.46}
              blending={THREE.AdditiveBlending}
              depthWrite={false}
            />
          </mesh>
        </group>

        {/* Leaning 12" Vinyl Sleeve (LUX) + Alabaster Pearl Vinyl Record Disc peeking out! */}
        <group position={[-0.12, 0.165, -0.04]} rotation={[-0.14, 0.12, 0]}>
          {/* Peeking 12" colored vinyl disc */}
          <mesh position={[0.095, 0, -0.008]} castShadow>
            <circleGeometry args={[0.132, 36]} />
            <meshStandardMaterial map={vinylTex} roughness={0.24} metalness={0.28} />
          </mesh>
          {/* Record jacket sleeve */}
          <mesh castShadow receiveShadow>
            <boxGeometry args={[0.275, 0.275, 0.012]} />
            <meshStandardMaterial color="#e6dfd4" roughness={0.7} />
          </mesh>
          <mesh position={[0, 0, 0.0072]}>
            <planeGeometry args={[0.27, 0.27]} />
            {shelfAlbumTex ? (
              <meshStandardMaterial
                key="shelf-art-loaded"
                map={shelfAlbumTex}
                emissiveMap={shelfAlbumTex}
                emissive="#ffffff"
                emissiveIntensity={0.08}
                roughness={0.62}
              />
            ) : (
              <meshStandardMaterial key="shelf-art-wait" color="#a6bdd4" roughness={0.7} />
            )}
          </mesh>
        </group>

        {/* Matte linen hardcover books */}
        <mesh position={[-0.41, 0.125, 0.0]} castShadow>
          <boxGeometry args={[0.042, 0.215, 0.16]} />
          <meshStandardMaterial color="#cfc4b4" roughness={0.86} />
        </mesh>
        <mesh position={[-0.355, 0.11, 0.0]} castShadow>
          <boxGeometry args={[0.044, 0.185, 0.155]} />
          <meshStandardMaterial color="#8faac4" roughness={0.82} />
        </mesh>
      </group>

      {/* ==================== Mi Smart Plug (Protected) + Mi Climate Sensor + Espresso Cup + Terracotta Eucalyptus ==================== */}
      <group
        position={[0.98, 0.72, -0.22]}
        onClick={(e) => {
          e.stopPropagation();
          const st = useHomeStore.getState();
          st.setSelectedTarget('plug');
          playTactileSound('tick', st.soundEnabled);
        }}
        onPointerOver={(e) => {
          e.stopPropagation();
          handleHover('plug');
        }}
        onPointerOut={() => handleHover(null)}
      >
        <mesh position={[0, 0.002, 0]} rotation={[-Math.PI / 2, 0, 0]}>
          <planeGeometry args={[0.24, 0.18]} />
          <meshBasicMaterial map={contactShadowTex} transparent opacity={0.64} depthWrite={false} />
        </mesh>
        <mesh position={[0, 0.03, 0]} castShadow receiveShadow>
          <boxGeometry args={[0.14, 0.058, 0.092]} />
          <meshStandardMaterial color="#f5f3ef" roughness={0.34} metalness={0.04} />
        </mesh>
        <mesh position={[-0.042, 0.061, 0.01]} rotation={[-Math.PI / 2, 0, 0]}>
          <ringGeometry args={[0.007, 0.012, 20]} />
          <meshStandardMaterial
            ref={plugLedMatRef}
            color="#22c55e"
            emissive="#16a34a"
            emissiveIntensity={1.75}
          />
        </mesh>
      </group>

      {/* Mi Temperature & Humidity Monitor 2 */}
      <group position={[0.78, 0.72, -0.26]} rotation={[0, -0.22, 0]}>
        <mesh position={[0, 0.048, 0]} rotation={[-0.14, 0, 0]} castShadow>
          <boxGeometry args={[0.095, 0.095, 0.022]} />
          <meshStandardMaterial color="#f5f3ef" roughness={0.36} />
        </mesh>
        <mesh position={[0, 0.048, 0.012]} rotation={[-0.14, 0, 0]}>
          <planeGeometry args={[0.088, 0.088]} />
          <meshStandardMaterial map={climateTex} roughness={0.6} />
        </mesh>
      </group>

      {/* Matte cream ceramic espresso cup + saucer + dark coffee surface (left foreground) */}
      <group position={[-0.78, 0.72, 0.24]}>
        <mesh position={[0, 0.004, 0]} castShadow receiveShadow>
          <cylinderGeometry args={[0.072, 0.058, 0.009, 28]} />
          <meshStandardMaterial color="#ede6db" roughness={0.42} />
        </mesh>
        <mesh geometry={mugGeo} position={[0, 0.008, 0]} castShadow receiveShadow>
          <meshStandardMaterial color="#f3ede4" roughness={0.38} />
        </mesh>
        {/* Glossy dark espresso crema inside cup */}
        <mesh position={[0, 0.078, 0]} rotation={[-Math.PI / 2, 0, 0]}>
          <circleGeometry args={[0.039, 24]} />
          <meshStandardMaterial color="#362216" roughness={0.14} metalness={0.08} />
        </mesh>
        <mesh position={[0.046, 0.054, 0]} rotation={[0, 0, -Math.PI / 2]}>
          <torusGeometry args={[0.023, 0.006, 10, 18, Math.PI]} />
          <meshStandardMaterial color="#f3ede4" roughness={0.38} />
        </mesh>
      </group>

      {/* Sculpted Terracotta Ceramic Vessel + Lush Multi-Branch Eucalyptus Foliage */}
      <group position={[1.22, 0.72, -0.26]}>
        <mesh position={[0, 0.002, 0]} rotation={[-Math.PI / 2, 0, 0]}>
          <planeGeometry args={[0.3, 0.3]} />
          <meshBasicMaterial map={contactShadowTex} transparent opacity={0.65} depthWrite={false} />
        </mesh>
        <mesh geometry={planterGeo} castShadow receiveShadow>
          <meshStandardMaterial color="#c47e5c" roughness={0.76} />
        </mesh>
        {/* Potting soil disc */}
        <mesh position={[0, 0.153, 0]} rotation={[-Math.PI / 2, 0, 0]}>
          <circleGeometry args={[0.064, 20]} />
          <meshStandardMaterial color="#4a3a2e" roughness={0.95} />
        </mesh>
        {/* 4 curved eucalyptus branches + varied sage leaves catching warm sunset rim light */}
        {[
          { rot: [0.16, 0.2, -0.20], h: 0.38, lx: -0.07, ly: 0.31, lz: 0.03 },
          { rot: [-0.14, 1.1, 0.14], h: 0.44, lx: 0.05, ly: 0.36, lz: -0.04 },
          { rot: [0.10, -0.9, 0.24], h: 0.34, lx: 0.08, ly: 0.27, lz: 0.05 },
          { rot: [-0.18, -2.1, -0.15], h: 0.30, lx: -0.05, ly: 0.24, lz: -0.05 },
        ].map((stem, idx) => (
          <group key={idx} position={[0, 0.14, 0]}>
            <mesh
              position={[stem.lx * 0.42, stem.h * 0.42, stem.lz * 0.42]}
              rotation={stem.rot as [number, number, number]}
              castShadow
            >
              <cylinderGeometry args={[0.0032, 0.0044, stem.h, 8]} />
              <meshStandardMaterial color="#586b58" roughness={0.85} />
            </mesh>
            <mesh position={[stem.lx, stem.ly, stem.lz]} rotation={[0.45, idx * 1.2, 0.32]} castShadow>
              <cylinderGeometry args={[0.036, 0.036, 0.005, 16]} />
              <meshStandardMaterial color="#7d937c" roughness={0.68} />
            </mesh>
            <mesh
              position={[stem.lx * 0.68, stem.ly - 0.065, stem.lz * 0.72]}
              rotation={[-0.38, idx * 1.8, -0.28]}
              castShadow
            >
              <cylinderGeometry args={[0.031, 0.031, 0.005, 16]} />
              <meshStandardMaterial color="#6e836e" roughness={0.72} />
            </mesh>
            <mesh
              position={[stem.lx * 0.42, stem.ly - 0.125, stem.lz * 0.48]}
              rotation={[0.22, idx * 2.3, 0.44]}
              castShadow
            >
              <cylinderGeometry args={[0.026, 0.026, 0.005, 16]} />
              <meshStandardMaterial color="#879c84" roughness={0.7} />
            </mesh>
          </group>
        ))}
      </group>
    </>
  );
}

export default function StudyScene3D({
  visible,
  reducedMotion,
  onReady,
  onFallback,
}: StudyScene3DProps) {
  const [dpr, setDpr] = useState(1.5);

  return (
    <Canvas
      shadows="percentage"
      frameloop={visible ? 'demand' : 'never'}
      dpr={[1, dpr]}
      camera={{ position: [0.12, 1.56, 5.06], fov: 35, near: 0.1, far: 30 }}
      gl={{
        antialias: true,
        powerPreference: 'high-performance',
        toneMapping: THREE.AgXToneMapping,
        toneMappingExposure: 0.94,
      }}
      onCreated={({ gl }) => {
        const canvas = gl.domElement;
        try {
          const rawGl = gl.getContext();
          const vs = rawGl.createShader(rawGl.VERTEX_SHADER);
          if (vs) {
            rawGl.shaderSource(vs, 'void main(){gl_Position=vec4(0.0);}');
            rawGl.compileShader(vs);
            const ok = rawGl.getShaderParameter(vs, rawGl.COMPILE_STATUS);
            rawGl.deleteShader(vs);
            if (!ok) {
              onFallback();
              return;
            }
          }
        } catch {
          onFallback();
          return;
        }
        const onLost = (e: Event) => {
          e.preventDefault();
          onFallback();
        };
        canvas.addEventListener('webglcontextlost', onLost, { once: true });
      }}
      className="h-full w-full"
    >
      <AdaptivePerformanceScaler onDprChange={setDpr} />
      <StudyCameraRig reducedMotion={reducedMotion} />
      <GoldenHourStudyContent onReady={onReady} />
    </Canvas>
  );
}
