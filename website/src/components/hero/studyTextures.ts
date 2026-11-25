import * as THREE from 'three';

/** High-resolution procedural Apple Store European White Oak textures (blonde-honey matte soap finish) */
export function createAppleOakTextures(): {
  map: THREE.CanvasTexture;
  roughnessMap: THREE.CanvasTexture;
  bumpMap: THREE.CanvasTexture;
} {
  const w = 1024;
  const h = 1024;

  const colorCanvas = document.createElement('canvas');
  colorCanvas.width = w;
  colorCanvas.height = h;
  const ctx = colorCanvas.getContext('2d')!;

  const roughCanvas = document.createElement('canvas');
  roughCanvas.width = w;
  roughCanvas.height = h;
  const rctx = roughCanvas.getContext('2d')!;

  const bumpCanvas = document.createElement('canvas');
  bumpCanvas.width = w;
  bumpCanvas.height = h;
  const bctx = bumpCanvas.getContext('2d')!;

  ctx.fillStyle = '#cfa97c';
  ctx.fillRect(0, 0, w, h);
  rctx.fillStyle = '#989898';
  rctx.fillRect(0, 0, w, h);
  bctx.fillStyle = '#808080';
  bctx.fillRect(0, 0, w, h);

  // 7 seamless laminated European White Oak staves (Apple Store table craft)
  const plankCount = 7;
  const plankH = h / plankCount;
  for (let p = 0; p < plankCount; p++) {
    const py = p * plankH;
    const toneShift = ((p * 41) % 15) - 7;
    for (let y = 0; y < plankH; y++) {
      const gy = py + y;
      const wave =
        Math.sin((y + p * 47) * 0.048) * 0.45 +
        Math.sin((y + p * 23) * 0.15) * 0.33 +
        Math.sin((y + p * 11) * 0.46) * 0.22;
      const r = Math.min(255, Math.max(0, Math.round(207 + toneShift + wave * 11)));
      const g = Math.min(255, Math.max(0, Math.round(173 + toneShift * 0.88 + wave * 9.5)));
      const b = Math.min(255, Math.max(0, Math.round(129 + toneShift * 0.72 + wave * 8)));
      ctx.fillStyle = `rgb(${r},${g},${b})`;
      ctx.fillRect(0, gy, w, 1);

      const rv = Math.round(146 + wave * 18);
      rctx.fillStyle = `rgb(${rv},${rv},${rv})`;
      rctx.fillRect(0, gy, w, 1);

      const bv = Math.round(128 + wave * 14);
      bctx.fillStyle = `rgb(${bv},${bv},${bv})`;
      bctx.fillRect(0, gy, w, 1);
    }

    // Whisper-fine architectural plank join
    ctx.fillStyle = 'rgba(116, 82, 48, 0.14)';
    ctx.fillRect(0, py, w, 1.4);
  }

  // Fine straight oak vessels, subtle cathedral grain & pale medullary ray flecks
  for (let i = 0; i < 1650; i++) {
    const x = (i * 211 + (i % 13) * 31) % w;
    const y = (i * 89 + (i % 7) * 19) % h;
    const len = 34 + ((i * 53) % 175);
    const isLightRay = i % 8 === 0;
    ctx.fillStyle = isLightRay
      ? 'rgba(248, 234, 210, 0.18)'
      : 'rgba(134, 96, 58, 0.16)';
    ctx.fillRect(x, y, len, isLightRay ? 2.1 : 1.1);

    bctx.fillStyle = isLightRay ? 'rgba(154,154,154,0.22)' : 'rgba(96,96,96,0.28)';
    bctx.fillRect(x, y, len, 1.2);
  }

  const map = new THREE.CanvasTexture(colorCanvas);
  map.colorSpace = THREE.SRGBColorSpace;
  map.wrapS = THREE.RepeatWrapping;
  map.wrapT = THREE.RepeatWrapping;
  map.repeat.set(1.5, 1);
  map.anisotropy = 8;

  const roughnessMap = new THREE.CanvasTexture(roughCanvas);
  roughnessMap.colorSpace = THREE.NoColorSpace;
  roughnessMap.wrapS = THREE.RepeatWrapping;
  roughnessMap.wrapT = THREE.RepeatWrapping;
  roughnessMap.repeat.set(1.5, 1);

  const bumpMap = new THREE.CanvasTexture(bumpCanvas);
  bumpMap.colorSpace = THREE.NoColorSpace;
  bumpMap.wrapS = THREE.RepeatWrapping;
  bumpMap.wrapT = THREE.RepeatWrapping;
  bumpMap.repeat.set(1.5, 1);

  return { map, roughnessMap, bumpMap };
}

/** Wide-plank pale European Oak hardwood floor textures */
export function createHardwoodFloorTextures(): {
  map: THREE.CanvasTexture;
  roughnessMap: THREE.CanvasTexture;
} {
  const w = 1024;
  const h = 1024;
  const c = document.createElement('canvas');
  c.width = w;
  c.height = h;
  const ctx = c.getContext('2d')!;

  const rc = document.createElement('canvas');
  rc.width = w;
  rc.height = h;
  const rctx = rc.getContext('2d')!;

  const rows = 8;
  const rowH = h / rows;
  for (let row = 0; row < rows; row++) {
    const y0 = row * rowH;
    const shift = ((row * 53) % 18) - 9;
    ctx.fillStyle = `rgb(${194 + shift}, ${167 + Math.round(shift * 0.85)}, ${134 + Math.round(shift * 0.7)})`;
    ctx.fillRect(0, y0, w, rowH);

    rctx.fillStyle = `rgb(${155 + shift}, ${155 + shift}, ${155 + shift})`;
    rctx.fillRect(0, y0, w, rowH);

    // Grain streaks
    for (let i = 0; i < 110; i++) {
      const gx = (i * 137 + row * 71) % w;
      const gy = y0 + ((i * 29) % (rowH - 4));
      ctx.fillStyle = i % 3 === 0 ? 'rgba(240,224,198,0.14)' : 'rgba(118,86,54,0.13)';
      ctx.fillRect(gx, gy, 55 + (i % 90), 1.4);
    }

    // Horizontal board groove
    ctx.fillStyle = 'rgba(92, 68, 44, 0.28)';
    ctx.fillRect(0, y0, w, 2);

    // Staggered vertical plank end joint
    const jointX = ((row * 317 + 180) % (w - 120)) + 60;
    ctx.fillStyle = 'rgba(92, 68, 44, 0.25)';
    ctx.fillRect(jointX, y0, 2, rowH);
  }

  const map = new THREE.CanvasTexture(c);
  map.colorSpace = THREE.SRGBColorSpace;
  map.wrapS = THREE.RepeatWrapping;
  map.wrapT = THREE.RepeatWrapping;
  map.repeat.set(3, 2);

  const roughnessMap = new THREE.CanvasTexture(rc);
  roughnessMap.colorSpace = THREE.NoColorSpace;
  roughnessMap.wrapS = THREE.RepeatWrapping;
  roughnessMap.wrapT = THREE.RepeatWrapping;
  roughnessMap.repeat.set(3, 2);

  return { map, roughnessMap };
}

/** Tactile oatmeal wool-felt desk mat with delicate stitched perimeter */
export function createFeltMatTexture(): THREE.CanvasTexture {
  const w = 512;
  const h = 256;
  const c = document.createElement('canvas');
  c.width = w;
  c.height = h;
  const ctx = c.getContext('2d')!;

  ctx.fillStyle = '#ddd4c6';
  ctx.fillRect(0, 0, w, h);

  // Fine merino wool felt heather fibers
  for (let i = 0; i < 7500; i++) {
    const x = (i * 113 + (i % 17) * 19) % w;
    const y = (i * 67 + (i % 13) * 23) % h;
    ctx.fillStyle =
      i % 3 === 0
        ? 'rgba(255, 251, 244, 0.16)'
        : i % 3 === 1
          ? 'rgba(128, 114, 98, 0.14)'
          : 'rgba(176, 162, 144, 0.12)';
    ctx.fillRect(x, y, 2, 1.5);
  }

  // Subtle inset perimeter stitch line
  ctx.strokeStyle = 'rgba(122, 108, 92, 0.32)';
  ctx.lineWidth = 1.5;
  ctx.setLineDash([5, 4]);
  roundRect(ctx, 10, 10, w - 20, h - 20, 12);
  ctx.stroke();

  const tex = new THREE.CanvasTexture(c);
  tex.colorSpace = THREE.SRGBColorSpace;
  tex.anisotropy = 4;
  return tex;
}

/** Woven ivory-oatmeal bouclé area rug texture */
export function createBoucleRugTexture(): THREE.CanvasTexture {
  const size = 256;
  const c = document.createElement('canvas');
  c.width = size;
  c.height = size;
  const ctx = c.getContext('2d')!;
  ctx.fillStyle = '#e7dfd2';
  ctx.fillRect(0, 0, size, size);
  for (let y = 0; y < size; y += 4) {
    for (let x = 0; x < size; x += 6) {
      const shade = ((x * 7 + y * 13) % 16) - 8;
      ctx.fillStyle = `rgb(${228 + shade}, ${219 + shade}, ${205 + shade})`;
      ctx.fillRect(x, y, 5, 3);
    }
  }
  const tex = new THREE.CanvasTexture(c);
  tex.colorSpace = THREE.SRGBColorSpace;
  tex.wrapS = THREE.RepeatWrapping;
  tex.wrapT = THREE.RepeatWrapping;
  tex.repeat.set(5, 3);
  return tex;
}

/** Warm Venetian lime-plaster architectural wall texture with soft baked ceiling & corner AO */
export function createWarmPlasterTexture(): THREE.CanvasTexture {
  const w = 1024;
  const h = 512;
  const canvas = document.createElement('canvas');
  canvas.width = w;
  canvas.height = h;
  const ctx = canvas.getContext('2d')!;

  const grad = ctx.createRadialGradient(w * 0.66, h * 0.44, 50, w * 0.5, h * 0.5, w * 0.68);
  grad.addColorStop(0, '#efe1cc');
  grad.addColorStop(0.55, '#e2d2bc');
  grad.addColorStop(1, '#cbb79d');
  ctx.fillStyle = grad;
  ctx.fillRect(0, 0, w, h);

  // Subtle top ceiling & bottom baseboard architectural Ambient Occlusion gradients
  const topAo = ctx.createLinearGradient(0, 0, 0, h * 0.14);
  topAo.addColorStop(0, 'rgba(84, 66, 48, 0.20)');
  topAo.addColorStop(1, 'rgba(84, 66, 48, 0)');
  ctx.fillStyle = topAo;
  ctx.fillRect(0, 0, w, h * 0.14);

  const botAo = ctx.createLinearGradient(0, h * 0.88, 0, h);
  botAo.addColorStop(0, 'rgba(84, 66, 48, 0)');
  botAo.addColorStop(1, 'rgba(84, 66, 48, 0.18)');
  ctx.fillStyle = botAo;
  ctx.fillRect(0, h * 0.88, w, h * 0.12);

  // Organic Venetian limewash clouding & mineral grain
  for (let i = 0; i < 9000; i++) {
    const x = (i * 151 + (i % 13) * 19) % w;
    const y = (i * 73 + (i % 11) * 23) % h;
    const a = 0.014 + (i % 4) * 0.006;
    ctx.fillStyle = i % 2 === 0 ? `rgba(255,248,238,${a})` : `rgba(104,82,58,${a * 1.15})`;
    ctx.fillRect(x, y, 2.5, 2);
  }

  const tex = new THREE.CanvasTexture(canvas);
  tex.colorSpace = THREE.SRGBColorSpace;
  return tex;
}

/** Warm woven oatmeal-linen drapery texture for motorized Mi curtains */
export function createLinenFabricTexture(): THREE.CanvasTexture {
  const size = 256;
  const canvas = document.createElement('canvas');
  canvas.width = size;
  canvas.height = size;
  const ctx = canvas.getContext('2d')!;

  ctx.fillStyle = '#efe6d8';
  ctx.fillRect(0, 0, size, size);

  for (let y = 0; y < size; y += 3) {
    ctx.fillStyle = y % 6 === 0 ? 'rgba(170, 146, 116, 0.16)' : 'rgba(255, 250, 240, 0.2)';
    ctx.fillRect(0, y, size, 1.2);
  }
  for (let x = 0; x < size; x += 3) {
    ctx.fillStyle = x % 6 === 0 ? 'rgba(160, 134, 104, 0.14)' : 'rgba(255, 248, 236, 0.15)';
    ctx.fillRect(x, 0, 1.2, size);
  }

  const tex = new THREE.CanvasTexture(canvas);
  tex.colorSpace = THREE.SRGBColorSpace;
  tex.wrapS = THREE.RepeatWrapping;
  tex.wrapT = THREE.RepeatWrapping;
  tex.repeat.set(3, 4);
  return tex;
}

/** 12-inch colored vinyl record texture (grooves + center label, alabaster pearl edition) */
export function createVinylDiscTexture(): THREE.CanvasTexture {
  const size = 256;
  const c = document.createElement('canvas');
  c.width = size;
  c.height = size;
  const ctx = c.getContext('2d')!;
  const cx = size / 2;
  const cy = size / 2;

  ctx.clearRect(0, 0, size, size);
  ctx.beginPath();
  ctx.arc(cx, cy, 122, 0, Math.PI * 2);
  ctx.fillStyle = '#e2dfd8';
  ctx.fill();

  // Concentric vinyl micro-grooves
  for (let r = 46; r < 118; r += 3) {
    ctx.beginPath();
    ctx.arc(cx, cy, r, 0, Math.PI * 2);
    ctx.strokeStyle = r % 6 === 0 ? 'rgba(140, 134, 122, 0.24)' : 'rgba(255, 253, 248, 0.35)';
    ctx.lineWidth = 1;
    ctx.stroke();
  }

  // Center cream archival pressing label
  ctx.beginPath();
  ctx.arc(cx, cy, 38, 0, Math.PI * 2);
  ctx.fillStyle = '#f5f0e4';
  ctx.fill();
  ctx.strokeStyle = 'rgba(120, 106, 86, 0.3)';
  ctx.lineWidth = 1.5;
  ctx.stroke();

  // Spindle hole
  ctx.beginPath();
  ctx.arc(cx, cy, 5, 0, Math.PI * 2);
  ctx.fillStyle = '#4a433b';
  ctx.fill();

  const tex = new THREE.CanvasTexture(c);
  tex.colorSpace = THREE.SRGBColorSpace;
  return tex;
}

/** Apple Magic Keyboard with Touch ID top keycap layout texture */
export function createKeyboardTexture(): THREE.CanvasTexture {
  const w = 512;
  const h = 192;
  const canvas = document.createElement('canvas');
  canvas.width = w;
  canvas.height = h;
  const ctx = canvas.getContext('2d')!;

  ctx.fillStyle = '#b4c9df';
  ctx.fillRect(0, 0, w, h);

  ctx.fillStyle = '#9ab3cd';
  roundRect(ctx, 12, 12, w - 24, h - 24, 10);
  ctx.fill();

  const rows = [
    { y: 18, h: 18, cols: 14 },
    { y: 42, h: 24, cols: 14 },
    { y: 72, h: 24, cols: 14 },
    { y: 102, h: 24, cols: 13 },
    { y: 132, h: 24, cols: 12 },
    { y: 162, h: 16, cols: 8 },
  ];

  const padX = 16;
  const availW = w - padX * 2;
  rows.forEach((row, rIdx) => {
    const gap = 4;
    if (rIdx === 5) {
      const widths = [34, 34, 42, 168, 42, 34, 48, 52];
      let cx = padX;
      widths.forEach((kw) => {
        ctx.fillStyle = '#f9f8f6';
        roundRect(ctx, cx, row.y, kw, row.h, 3.5);
        ctx.fill();
        cx += kw + gap;
      });
      return;
    }
    const kw = (availW - gap * (row.cols - 1)) / row.cols;
    for (let c = 0; c < row.cols; c++) {
      const kx = padX + c * (kw + gap);
      const isTouchId = rIdx === 0 && c === row.cols - 1;
      ctx.fillStyle = '#f9f8f6';
      roundRect(ctx, kx, row.y, kw, row.h, 3.5);
      ctx.fill();
      if (isTouchId) {
        ctx.strokeStyle = '#8fa9c4';
        ctx.lineWidth = 1.6;
        ctx.beginPath();
        ctx.arc(kx + kw / 2, row.y + row.h / 2, 5.5, 0, Math.PI * 2);
        ctx.stroke();
      }
    }
  });

  const tex = new THREE.CanvasTexture(canvas);
  tex.colorSpace = THREE.SRGBColorSpace;
  return tex;
}

/** Crisp minimalist Mi Wall Air Conditioner front panel LED readout */
export function drawAcDisplayCanvas(
  canvas: HTMLCanvasElement,
  acOn: boolean,
  acTemp: number
): void {
  const w = canvas.width;
  const h = canvas.height;
  const ctx = canvas.getContext('2d');
  if (!ctx) return;

  ctx.fillStyle = '#f2f0eb';
  ctx.fillRect(0, 0, w, h);

  ctx.fillStyle = 'rgba(145, 140, 132, 0.24)';
  ctx.fillRect(16, h * 0.72, w - 32, 2);

  ctx.fillStyle = 'rgba(130, 126, 120, 0.25)';
  ctx.beginPath();
  ctx.arc(36, h * 0.42, 6, 0, Math.PI * 2);
  ctx.fill();

  if (acOn) {
    ctx.fillStyle = 'rgba(30, 38, 48, 0.08)';
    ctx.beginPath();
    ctx.arc(w - 72, h * 0.44, 24, 0, Math.PI * 2);
    ctx.fill();

    ctx.fillStyle = '#2563eb';
    ctx.font = '600 24px "Inter Variable", system-ui, sans-serif';
    ctx.textAlign = 'center';
    ctx.textBaseline = 'middle';
    ctx.fillText(`${acTemp}°`, w - 72, h * 0.44);

    ctx.fillStyle = '#38bdf8';
    ctx.beginPath();
    ctx.arc(w - 36, h * 0.44, 3.5, 0, Math.PI * 2);
    ctx.fill();
  }
}

/** Crisp e-ink face for Mi Temperature & Humidity Monitor 2 on the desk */
export function createClimatePuckTexture(): THREE.CanvasTexture {
  const size = 256;
  const canvas = document.createElement('canvas');
  canvas.width = size;
  canvas.height = size;
  const ctx = canvas.getContext('2d')!;

  ctx.fillStyle = '#f5f3ee';
  ctx.fillRect(0, 0, size, size);

  ctx.fillStyle = '#e5e3db';
  roundRect(ctx, 26, 26, size - 52, size - 52, 20);
  ctx.fill();
  ctx.strokeStyle = 'rgba(50, 46, 40, 0.14)';
  ctx.lineWidth = 2;
  ctx.stroke();

  ctx.fillStyle = '#2a2825';
  ctx.textAlign = 'center';
  ctx.font = '600 62px "Inter Variable", system-ui, sans-serif';
  ctx.fillText('25.8°', size / 2, 120);

  ctx.fillStyle = '#57534e';
  ctx.font = '500 30px "Inter Variable", system-ui, sans-serif';
  ctx.fillText('58%  ·  ◡', size / 2, 178);

  const tex = new THREE.CanvasTexture(canvas);
  tex.colorSpace = THREE.SRGBColorSpace;
  return tex;
}

/** Soft-edged warm golden sunset window-mullion light projection patch */
export function createSunPatchTexture(): THREE.CanvasTexture {
  const w = 512;
  const h = 512;
  const canvas = document.createElement('canvas');
  canvas.width = w;
  canvas.height = h;
  const ctx = canvas.getContext('2d')!;

  ctx.clearRect(0, 0, w, h);

  const grad = ctx.createLinearGradient(w, 0, 0, h);
  grad.addColorStop(0, 'rgba(255, 192, 112, 0.88)');
  grad.addColorStop(0.52, 'rgba(255, 168, 84, 0.56)');
  grad.addColorStop(1, 'rgba(255, 144, 62, 0.0)');

  ctx.save();
  ctx.filter = 'blur(14px)';
  ctx.fillStyle = grad;
  ctx.fillRect(42, 48, 196, 188);
  ctx.fillRect(268, 48, 196, 188);
  ctx.fillRect(42, 264, 196, 188);
  ctx.fillRect(268, 264, 196, 188);
  ctx.restore();

  const tex = new THREE.CanvasTexture(canvas);
  tex.colorSpace = THREE.SRGBColorSpace;
  return tex;
}

/** Soft radial warm amber halo texture for Home Switch Monolith */
export function createAmberHaloTexture(): THREE.CanvasTexture {
  const size = 256;
  const canvas = document.createElement('canvas');
  canvas.width = size;
  canvas.height = size;
  const ctx = canvas.getContext('2d')!;
  const g = ctx.createRadialGradient(size / 2, size / 2, 10, size / 2, size / 2, size / 2);
  g.addColorStop(0, 'rgba(255, 194, 96, 0.86)');
  g.addColorStop(0.4, 'rgba(245, 158, 42, 0.34)');
  g.addColorStop(0.74, 'rgba(235, 130, 32, 0.08)');
  g.addColorStop(1, 'rgba(235, 130, 32, 0)');
  ctx.fillStyle = g;
  ctx.fillRect(0, 0, size, size);

  const tex = new THREE.CanvasTexture(canvas);
  tex.colorSpace = THREE.SRGBColorSpace;
  return tex;
}

/** Soft warm ambient contact shadow texture */
export function createContactShadowTexture(): THREE.CanvasTexture {
  const size = 128;
  const canvas = document.createElement('canvas');
  canvas.width = size;
  canvas.height = size;
  const ctx = canvas.getContext('2d')!;
  const g = ctx.createRadialGradient(size / 2, size / 2, 6, size / 2, size / 2, size / 2);
  g.addColorStop(0, 'rgba(46, 32, 18, 0.46)');
  g.addColorStop(0.55, 'rgba(46, 32, 18, 0.18)');
  g.addColorStop(1, 'rgba(46, 32, 18, 0)');
  ctx.fillStyle = g;
  ctx.fillRect(0, 0, size, size);

  const tex = new THREE.CanvasTexture(canvas);
  tex.colorSpace = THREE.SRGBColorSpace;
  return tex;
}

export interface IMacScreenDrawParams {
  lampOn: boolean;
  lampBrightness: number;
  lampKelvin: number;
  ceilingOn: boolean;
  ceilingBrightness: number;
  ceilingKelvin: number;
  lightBarOn: boolean;
  curtainOpen: number;
  acOn: boolean;
  acTemp: number;
  plugOn: boolean;
  pipPinned: boolean;
  searchQuery: string;
  focused: boolean;
}

/** Draw crisp 1280x720 macOS Sequoia desktop inside the Blue M4 iMac */
export function drawIMacDisplayCanvas(
  canvas: HTMLCanvasElement,
  params: IMacScreenDrawParams
): void {
  const w = canvas.width;
  const h = canvas.height;
  const ctx = canvas.getContext('2d');
  if (!ctx) return;

  const bg = ctx.createLinearGradient(0, 0, w, h);
  const sunsetFactor = params.curtainOpen / 100;
  bg.addColorStop(0, sunsetFactor > 0.35 ? '#203d62' : '#142438');
  bg.addColorStop(0.46, sunsetFactor > 0.35 ? '#4874a2' : '#243a56');
  bg.addColorStop(0.78, sunsetFactor > 0.35 ? '#d48654' : '#463a39');
  bg.addColorStop(1, sunsetFactor > 0.35 ? '#ebb078' : '#211c1d');
  ctx.fillStyle = bg;
  ctx.fillRect(0, 0, w, h);

  // Flowing Apple M4 iMac geometric ribbon curves
  ctx.save();
  ctx.beginPath();
  ctx.moveTo(0, h * 0.72);
  ctx.bezierCurveTo(w * 0.25, h * 0.42, w * 0.62, h * 0.88, w, h * 0.56);
  ctx.lineTo(w, h);
  ctx.lineTo(0, h);
  ctx.closePath();
  const wave1 = ctx.createLinearGradient(0, h * 0.45, w, h);
  wave1.addColorStop(0, 'rgba(56, 102, 154, 0.62)');
  wave1.addColorStop(0.55, 'rgba(128, 170, 212, 0.44)');
  wave1.addColorStop(1, 'rgba(244, 178, 118, 0.58)');
  ctx.fillStyle = wave1;
  ctx.fill();

  ctx.beginPath();
  ctx.moveTo(0, h * 0.86);
  ctx.bezierCurveTo(w * 0.34, h * 0.68, w * 0.68, h * 0.94, w, h * 0.76);
  ctx.lineTo(w, h);
  ctx.lineTo(0, h);
  ctx.closePath();
  ctx.fillStyle = 'rgba(26, 46, 74, 0.34)';
  ctx.fill();
  ctx.restore();

  // macOS top translucent menu bar
  ctx.fillStyle = 'rgba(252, 249, 244, 0.78)';
  ctx.fillRect(0, 0, w, 36);
  ctx.fillStyle = 'rgba(30, 26, 22, 0.08)';
  ctx.fillRect(0, 36, w, 1);

  ctx.fillStyle = '#1e1a16';
  ctx.textAlign = 'left';
  ctx.textBaseline = 'alphabetic';
  ctx.font = '600 14px "Inter Variable", system-ui, sans-serif';
  ctx.fillText('   MenuBarHome', 22, 23);
  ctx.fillStyle = 'rgba(30, 26, 22, 0.62)';
  ctx.font = '400 13px "Inter Variable", system-ui, sans-serif';
  ctx.fillText('File   Edit   View   Rooms   Window', 170, 23);

  const activeCount =
    (params.lampOn ? 1 : 0) +
    (params.ceilingOn ? 1 : 0) +
    (params.lightBarOn ? 1 : 0) +
    (params.acOn ? 1 : 0) +
    (params.plugOn ? 1 : 0);

  const pillX = w - 268;
  ctx.fillStyle = params.focused ? 'rgba(217, 119, 6, 0.24)' : 'rgba(30, 26, 22, 0.1)';
  roundRect(ctx, pillX, 5, 134, 26, 13);
  ctx.fill();
  ctx.fillStyle = params.lampOn || params.ceilingOn ? '#d97706' : '#71685e';
  ctx.beginPath();
  ctx.arc(pillX + 18, 18, 5.5, 0, Math.PI * 2);
  ctx.fill();
  ctx.fillStyle = '#1e1a16';
  ctx.font = '600 12.5px "Inter Variable", system-ui, sans-serif';
  ctx.fillText(`25.8° · ${activeCount} on`, pillX + 32, 22);

  ctx.fillStyle = 'rgba(30, 26, 22, 0.78)';
  ctx.font = '500 13px "Inter Variable", system-ui, sans-serif';
  ctx.fillText('Thu 17:42', w - 114, 23);

  // Left non-activating macOS editor window
  const edX = 52;
  const edY = 74;
  const edW = 588;
  const edH = 510;
  ctx.fillStyle = 'rgba(253, 251, 247, 0.92)';
  roundRect(ctx, edX, edY, edW, edH, 16);
  ctx.fill();
  ctx.strokeStyle = 'rgba(38, 30, 22, 0.14)';
  ctx.lineWidth = 1.2;
  ctx.stroke();

  ['#ff5f57', '#febc2e', '#28c840'].forEach((col, idx) => {
    ctx.fillStyle = col;
    ctx.beginPath();
    ctx.arc(edX + 22 + idx * 18, edY + 21, 5.5, 0, Math.PI * 2);
    ctx.fill();
  });
  ctx.fillStyle = '#5b5349';
  ctx.font = '500 12.5px ui-monospace, Menlo, monospace';
  ctx.fillText('LocalMiIOClient.swift — MenuBarHome', edX + 86, edY + 25);

  ctx.fillStyle = 'rgba(38, 30, 22, 0.07)';
  ctx.fillRect(edX, edY + 42, edW, 1);

  const lines = [
    'actor LocalMiIOClient {',
    '  let udpPort: UInt16 = 54321',
    '  func syncGoldenHourStudy() async throws {',
    `    // Mi Desk Lamp 1S : ${params.lampOn ? `${params.lampBrightness}% · ${params.lampKelvin}K` : 'off'}`,
    `    // Mi Ceiling Light: ${params.ceilingOn ? `${params.ceilingBrightness}% · ${params.ceilingKelvin}K` : 'off'}`,
    `    // Monitor LightBar: ${params.lightBarOn ? 'on (asymmetric)' : 'off'}`,
    `    // Curtain Motor   : ${params.curtainOpen}% open (sunset beam)`,
    `    // Mi Wall AC      : ${params.acOn ? `cool ${params.acTemp}°C` : 'standby'}`,
    '    try await sendEncryptedUDP(payload)',
    '  }',
    '}',
  ];
  lines.forEach((line, i) => {
    ctx.fillStyle = line.trim().startsWith('//')
      ? '#b45309'
      : i === 0 || i === 2
        ? '#1e1a16'
        : '#5b5349';
    ctx.font = '400 14.5px ui-monospace, Menlo, monospace';
    ctx.fillText(line, edX + 26, edY + 84 + i * 33);
  });

  // In overview mode, show a subtle clean desktop cue badge; in focused mode mirror Liquid Glass pills inside the desktop
  if (!params.focused) {
    const hintW = 360;
    const hintH = 122;
    const hx = w - hintW - 52;
    const hy = 74;
    ctx.fillStyle = 'rgba(255, 253, 248, 0.56)';
    roundRect(ctx, hx, hy, hintW, hintH, 24);
    ctx.fill();
    ctx.strokeStyle = 'rgba(255, 255, 255, 0.85)';
    ctx.lineWidth = 1.5;
    ctx.stroke();

    ctx.fillStyle = '#f59e0b';
    ctx.beginPath();
    ctx.arc(hx + 38, hy + 61, 20, 0, Math.PI * 2);
    ctx.fill();

    ctx.fillStyle = '#1e1a16';
    ctx.font = '600 17px "Inter Variable", system-ui, sans-serif';
    ctx.fillText('Golden-Hour Study', hx + 72, hy + 52);
    ctx.fillStyle = '#4a433b';
    ctx.font = '400 13px "Inter Variable", system-ui, sans-serif';
    ctx.fillText(`${activeCount} active · Click iMac to control`, hx + 72, hy + 76);
  } else {
    // Floating translucent Liquid Glass pill summaries on right side of iMac desktop
    const px = w - 392;
    const items = [
      { name: 'Mi Desk Lamp 1S', sub: params.lampOn ? `${params.lampBrightness}% · ${params.lampKelvin}K` : 'Off', on: params.lampOn, orb: '#ff9500' },
      { name: 'Mi Ceiling Light', sub: params.ceilingOn ? `${params.ceilingBrightness}% · ${params.ceilingKelvin}K` : 'Off', on: params.ceilingOn, orb: '#f59e0b' },
      { name: 'Motorized Curtains', sub: `${params.curtainOpen}% Open`, on: params.curtainOpen > 15, orb: '#d97706' },
      { name: 'Mi Wall AC', sub: params.acOn ? `Cool · ${params.acTemp}°C` : 'Standby', on: params.acOn, orb: '#0284c7' },
      { name: 'Mi Smart Plug', sub: 'Protected · 42W', on: params.plugOn, orb: '#1d9a48' },
    ];
    items.forEach((it, idx) => {
      const ty = 64 + idx * 78;
      ctx.fillStyle = 'rgba(255, 253, 248, 0.56)';
      roundRect(ctx, px, ty, 344, 64, 24);
      ctx.fill();
      ctx.strokeStyle = 'rgba(255, 255, 255, 0.85)';
      ctx.lineWidth = 1.4;
      ctx.stroke();

      ctx.fillStyle = it.on ? it.orb : 'rgba(38, 30, 22, 0.16)';
      ctx.beginPath();
      ctx.arc(px + 34, ty + 32, 16, 0, Math.PI * 2);
      ctx.fill();

      ctx.fillStyle = '#1e1a16';
      ctx.font = '600 14.5px "Inter Variable", system-ui, sans-serif';
      ctx.fillText(it.name, px + 62, ty + 28);
      ctx.fillStyle = '#4a433b';
      ctx.font = '400 12px "Inter Variable", system-ui, sans-serif';
      ctx.fillText(it.sub, px + 62, ty + 47);
    });
  }

  if (params.pipPinned) {
    ctx.fillStyle = 'rgba(24, 22, 20, 0.92)';
    roundRect(ctx, edX + 362, edY + 340, 204, 142, 14);
    ctx.fill();
    ctx.strokeStyle = '#4a78ab';
    ctx.lineWidth = 2;
    ctx.stroke();
    ctx.fillStyle = '#f6f2eb';
    ctx.font = '600 12px "Inter Variable", system-ui, sans-serif';
    ctx.fillText('FRONT DOOR · PiP', edX + 378, edY + 366);
    ctx.fillStyle = '#9ebbd8';
    ctx.fillText('LIVE · VIDEO ONLY', edX + 378, edY + 464);
  }

  // Translucent macOS Liquid Glass Dock centered at bottom
  const dockW = 360;
  const dockH = 52;
  const dockX = (w - dockW) / 2;
  const dockY = h - 66;
  ctx.fillStyle = 'rgba(255, 252, 248, 0.56)';
  roundRect(ctx, dockX, dockY, dockW, dockH, 18);
  ctx.fill();
  ctx.strokeStyle = 'rgba(255, 255, 255, 0.72)';
  ctx.lineWidth = 1.2;
  ctx.stroke();

  const dockColors = ['#4a90e2', '#34c759', '#f59e0b', '#1e1a16', '#4a78ab', '#ef4444', '#8e8e93'];
  dockColors.forEach((col, i) => {
    const ix = dockX + 22 + i * 47;
    ctx.fillStyle = col;
    roundRect(ctx, ix, dockY + 8, 36, 36, 9);
    ctx.fill();
  });
}

function roundRect(
  ctx: CanvasRenderingContext2D,
  x: number,
  y: number,
  w: number,
  h: number,
  r: number
): void {
  ctx.beginPath();
  ctx.moveTo(x + r, y);
  ctx.arcTo(x + w, y, x + w, y + h, r);
  ctx.arcTo(x + w, y + h, x, y + h, r);
  ctx.arcTo(x, y + h, x, y, r);
  ctx.arcTo(x, y, x + w, y, r);
  ctx.closePath();
}
