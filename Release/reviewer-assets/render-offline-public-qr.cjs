#!/usr/bin/env node

const crypto = require('crypto');
const fs = require('fs');
const path = require('path');
const zlib = require('zlib');
const { execFileSync } = require('child_process');

const assetDirectory = __dirname;
const payloadPath = path.join(assetDirectory, 'offline-public-qr-payload.txt');
const outputPath = path.join(assetDirectory, 'test-qr.png');
const payload = fs.readFileSync(payloadPath, 'utf8').trim();
const scale = 8;
const quietZoneModules = 4;

function loadQRCode() {
  const npmRoot = execFileSync('npm', ['root', '-g'], { encoding: 'utf8' }).trim();
  const candidates = [
    path.join(npmRoot, 'qrcode-terminal', 'vendor', 'QRCode'),
    path.join(npmRoot, 'npm', 'node_modules', 'qrcode-terminal', 'vendor', 'QRCode'),
  ];
  const implementation = candidates.find(candidate => fs.existsSync(`${candidate}/index.js`));
  if (!implementation) {
    throw new Error('qrcode-terminal is unavailable in the npm installation; refusing to emit an unverified substitute');
  }
  const packageRoot = path.dirname(path.dirname(implementation));
  const packageMetadata = JSON.parse(fs.readFileSync(path.join(packageRoot, 'package.json'), 'utf8'));
  if (packageMetadata.version !== '0.12.0') {
    throw new Error(`qrcode-terminal 0.12.0 is required, found ${packageMetadata.version}`);
  }
  return {
    QRCode: require(implementation),
    level: require(path.join(implementation, 'QRErrorCorrectLevel')).M,
  };
}

function crc32(buffer) {
  let crc = 0xffffffff;
  for (const byte of buffer) {
    crc ^= byte;
    for (let bit = 0; bit < 8; bit += 1) {
      crc = (crc >>> 1) ^ (crc & 1 ? 0xedb88320 : 0);
    }
  }
  return (crc ^ 0xffffffff) >>> 0;
}

function chunk(name, data) {
  const type = Buffer.from(name, 'ascii');
  const length = Buffer.alloc(4);
  length.writeUInt32BE(data.length);
  const checksum = Buffer.alloc(4);
  checksum.writeUInt32BE(crc32(Buffer.concat([type, data])));
  return Buffer.concat([length, type, data, checksum]);
}

function encodeRGBPNG(width, height, pixels) {
  const header = Buffer.alloc(13);
  header.writeUInt32BE(width, 0);
  header.writeUInt32BE(height, 4);
  header[8] = 8;
  header[9] = 2;
  header[10] = 0;
  header[11] = 0;
  header[12] = 0;

  const scanlines = Buffer.alloc((width * 3 + 1) * height);
  for (let row = 0; row < height; row += 1) {
    const target = row * (width * 3 + 1);
    scanlines[target] = 0;
    for (let column = 0; column < width; column += 1) {
      const value = pixels[row * width + column];
      const pixelTarget = target + 1 + column * 3;
      scanlines[pixelTarget] = value;
      scanlines[pixelTarget + 1] = value;
      scanlines[pixelTarget + 2] = value;
    }
  }
  const compressed = zlib.deflateSync(scanlines, { level: 9 });
  return Buffer.concat([
    Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]),
    chunk('IHDR', header),
    chunk('IDAT', compressed),
    chunk('IEND', Buffer.alloc(0)),
  ]);
}

const { QRCode, level } = loadQRCode();
const qr = new QRCode(-1, level);
qr.addData(payload);
qr.make();

const moduleCount = qr.getModuleCount();
const side = (moduleCount + quietZoneModules * 2) * scale;
const pixels = Buffer.alloc(side * side, 255);
for (let row = 0; row < moduleCount; row += 1) {
  for (let column = 0; column < moduleCount; column += 1) {
    if (!qr.isDark(row, column)) continue;
    const originY = (row + quietZoneModules) * scale;
    const originX = (column + quietZoneModules) * scale;
    for (let y = originY; y < originY + scale; y += 1) {
      pixels.fill(0, y * side + originX, y * side + originX + scale);
    }
  }
}

const png = encodeRGBPNG(side, side, pixels);
const temporaryPath = `${outputPath}.tmp-${process.pid}`;
fs.writeFileSync(temporaryPath, png);
fs.renameSync(temporaryPath, outputPath);
console.log(`Rendered ${side}x${side} deterministic QR (${crypto.createHash('sha256').update(png).digest('hex')}).`);
