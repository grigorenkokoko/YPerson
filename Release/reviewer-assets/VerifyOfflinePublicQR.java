import com.google.zxing.BinaryBitmap;
import com.google.zxing.LuminanceSource;
import com.google.zxing.MultiFormatReader;
import com.google.zxing.Result;
import com.google.zxing.common.HybridBinarizer;
import java.awt.image.BufferedImage;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import javax.imageio.ImageIO;

public final class VerifyOfflinePublicQR {
    public static void main(String[] arguments) throws Exception {
        if (arguments.length != 2) {
            throw new IllegalArgumentException("usage: VerifyOfflinePublicQR image.png payload.txt");
        }
        BufferedImage image = ImageIO.read(Path.of(arguments[0]).toFile());
        if (image == null) {
            throw new IllegalStateException("PNG cannot be opened");
        }
        Result result = new MultiFormatReader().decode(new BinaryBitmap(
            new HybridBinarizer(new ImageLuminanceSource(image))
        ));
        String expected = Files.readString(Path.of(arguments[1]), StandardCharsets.UTF_8).trim();
        if (!result.getText().equals(expected)) {
            throw new IllegalStateException("decoded QR payload does not equal the source payload");
        }
        System.out.printf(
            "ZXing decoded the exact %d-byte payload from %dx%d PNG.%n",
            expected.getBytes(StandardCharsets.UTF_8).length,
            image.getWidth(),
            image.getHeight()
        );
    }

    private static final class ImageLuminanceSource extends LuminanceSource {
        private final byte[] luminances;

        ImageLuminanceSource(BufferedImage image) {
            super(image.getWidth(), image.getHeight());
            luminances = new byte[getWidth() * getHeight()];
            for (int y = 0; y < getHeight(); y += 1) {
                for (int x = 0; x < getWidth(); x += 1) {
                    int rgb = image.getRGB(x, y);
                    int red = (rgb >>> 16) & 0xff;
                    int green = (rgb >>> 8) & 0xff;
                    int blue = rgb & 0xff;
                    luminances[y * getWidth() + x] = (byte) ((red + green * 2 + blue) / 4);
                }
            }
        }

        @Override
        public byte[] getRow(int y, byte[] row) {
            if (y < 0 || y >= getHeight()) {
                throw new IllegalArgumentException("requested row is outside the image");
            }
            if (row == null || row.length < getWidth()) {
                row = new byte[getWidth()];
            }
            System.arraycopy(luminances, y * getWidth(), row, 0, getWidth());
            return row;
        }

        @Override
        public byte[] getMatrix() {
            return luminances.clone();
        }
    }
}
