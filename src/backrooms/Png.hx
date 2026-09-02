// A PNG encoder for Flash 10.1, which has no BitmapData.encode (that is 11.3).
// Truecolour, 8 bits, no filter, zlib via ByteArray.compress(). Used only for
// snapshots sent back to the PC, so speed matters less than being right.
import flash.display.BitmapData;
import flash.geom.Rectangle;
import flash.utils.ByteArray;

class Png {
    static var crcTable:flash.Vector<UInt>;

    public static function encode(bmd:BitmapData):ByteArray {
        var w = bmd.width, h = bmd.height;
        var px = bmd.getVector(new Rectangle(0, 0, w, h));
        var raw = new ByteArray();
        var i = 0;
        for (y in 0...h) {
            raw.writeByte(0);
            for (x in 0...w) {
                var c = px[i++];
                raw.writeByte((c >> 16) & 0xFF);
                raw.writeByte((c >> 8) & 0xFF);
                raw.writeByte(c & 0xFF);
            }
        }
        raw.compress();
        var out = new ByteArray();
        out.writeUnsignedInt(0x89504E47);
        out.writeUnsignedInt(0x0D0A1A0A);
        var ihdr = new ByteArray();
        ihdr.writeUnsignedInt(w); ihdr.writeUnsignedInt(h);
        ihdr.writeByte(8); ihdr.writeByte(2); ihdr.writeByte(0); ihdr.writeByte(0); ihdr.writeByte(0);
        chunk(out, 0x49484452, ihdr);
        chunk(out, 0x49444154, raw);
        chunk(out, 0x49454E44, new ByteArray());
        return out;
    }

    static function chunk(out:ByteArray, type:UInt, data:ByteArray):Void {
        out.writeUnsignedInt(data.length);
        var start = out.length;
        out.writeUnsignedInt(type);
        out.writeBytes(data);
        out.writeUnsignedInt(crc(out, start, out.length - start));
    }

    static function crc(b:ByteArray, start:Int, len:Int):UInt {
        if (crcTable == null) {
            crcTable = new flash.Vector<UInt>(256, true);
            for (n in 0...256) {
                var c:UInt = n;
                for (k in 0...8) c = (c & 1) != 0 ? (0xEDB88320 ^ (c >>> 1)) : (c >>> 1);
                crcTable[n] = c;
            }
        }
        var c:UInt = 0xFFFFFFFF;
        for (i in start...(start + len)) c = crcTable[(c ^ b[i]) & 0xFF] ^ (c >>> 8);
        return c ^ 0xFFFFFFFF;
    }
}
