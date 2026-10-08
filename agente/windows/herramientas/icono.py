#!/usr/bin/env python3
"""Genera icono.ico: una impresora blanca sobre un cuadro azul.

Sin dependencias a propósito (ni Pillow): el icono se dibuja con formas
simples, muestreando cada píxel varias veces para suavizar los bordes, y se
guarda en un .ico con los tamaños que pide Windows.

Los tamaños pequeños van como mapa de bits (DIB) y el de 256 como PNG: así lo
leen igual el compilador, el Explorador y `System.Drawing.Icon` de .NET
Framework, que con un PNG en 16 o 32 se queja.

    python3 herramientas/icono.py        # escribe ../icono.ico
"""

import os
import struct
import zlib

AZUL = (37, 99, 235)
BLANCO = (255, 255, 255)


def dentro_rect_redondo(x, y, x0, y0, x1, y1, r):
    if x < x0 or x > x1 or y < y0 or y > y1:
        return False
    cx = min(max(x, x0 + r), x1 - r)
    cy = min(max(y, y0 + r), y1 - r)
    return (x - cx) ** 2 + (y - cy) ** 2 <= r * r


def color(x, y):
    """Color (r, g, b, a) del punto (x, y), con x e y entre 0 y 1."""
    if not dentro_rect_redondo(x, y, 0.03, 0.03, 0.97, 0.97, 0.2):
        return None
    # La hoja que entra por arriba, el cuerpo y la hoja que sale.
    if dentro_rect_redondo(x, y, 0.31, 0.17, 0.69, 0.42, 0.02):
        return BLANCO
    if dentro_rect_redondo(x, y, 0.17, 0.38, 0.83, 0.71, 0.07):
        if 0.27 <= x <= 0.73 and 0.585 <= y <= 0.63:
            return AZUL  # la ranura
        if (x - 0.73) ** 2 + (y - 0.47) ** 2 <= 0.028 ** 2:
            return AZUL  # el piloto
        if not (0.31 <= x <= 0.69 and y >= 0.61):
            return BLANCO
    if 0.31 <= x <= 0.69 and 0.61 <= y <= 0.85:
        for y0, y1 in ((0.69, 0.715), (0.75, 0.775)):
            if 0.38 <= x <= 0.62 and y0 <= y <= y1:
                return AZUL  # renglones impresos
        return BLANCO
    return AZUL


def dibuja(n, muestras=6):
    pixeles = []
    for fila in range(n):
        for col in range(n):
            r = g = b = a = 0
            for sy in range(muestras):
                for sx in range(muestras):
                    c = color((col + (sx + 0.5) / muestras) / n,
                              (fila + (sy + 0.5) / muestras) / n)
                    if c is not None:
                        r += c[0]
                        g += c[1]
                        b += c[2]
                        a += 1
            total = muestras * muestras
            if a:
                pixeles.append((r // a, g // a, b // a, 255 * a // total))
            else:
                pixeles.append((0, 0, 0, 0))
    return pixeles


def png(n, pixeles):
    crudo = b''.join(
        b'\x00' + b''.join(struct.pack('4B', *pixeles[f * n + c]) for c in range(n))
        for f in range(n)
    )

    def trozo(tipo, datos):
        return (struct.pack('>I', len(datos)) + tipo + datos
                + struct.pack('>I', zlib.crc32(tipo + datos) & 0xFFFFFFFF))

    return (b'\x89PNG\r\n\x1a\n'
            + trozo(b'IHDR', struct.pack('>IIBBBBB', n, n, 8, 6, 0, 0, 0))
            + trozo(b'IDAT', zlib.compress(crudo, 9))
            + trozo(b'IEND', b''))


def dib(n, pixeles):
    cabecera = struct.pack('<IiiHHIIiiII', 40, n, n * 2, 1, 32, 0, 0, 0, 0, 0, 0)
    # De abajo arriba y en BGRA, como manda el formato.
    color_ = b''.join(
        struct.pack('4B', p[2], p[1], p[0], p[3])
        for f in reversed(range(n)) for p in pixeles[f * n:(f + 1) * n]
    )
    # Máscara AND a cero: la transparencia la lleva el canal alfa.
    mascara = b'\x00' * (((n + 31) // 32) * 4 * n)
    return cabecera + color_ + mascara


def main():
    tamanos = [16, 20, 24, 32, 40, 48, 64, 256]
    imagenes = []
    for n in tamanos:
        p = dibuja(n, muestras=4 if n > 64 else 8)
        imagenes.append(png(n, p) if n >= 256 else dib(n, p))

    salida = struct.pack('<HHH', 0, 1, len(tamanos))
    desplazamiento = 6 + 16 * len(tamanos)
    for n, datos in zip(tamanos, imagenes):
        lado = 0 if n >= 256 else n
        salida += struct.pack('<BBBBHHII', lado, lado, 0, 0, 1, 32, len(datos), desplazamiento)
        desplazamiento += len(datos)
    salida += b''.join(imagenes)

    ruta = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'icono.ico')
    with open(ruta, 'wb') as f:
        f.write(salida)
    print(f'{os.path.normpath(ruta)}: {len(salida)} bytes, {len(tamanos)} tamaños')


if __name__ == '__main__':
    main()
