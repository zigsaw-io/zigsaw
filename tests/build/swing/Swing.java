import java.awt.*;
import java.awt.font.TextLayout;
import java.util.concurrent.*;
import javax.swing.*;

// A Swing window that lays out and draws its text, then closes itself: the
// text goes through Java's layout engine, as diagrams' and documents' do.
public class Swing {
    public static void main(String[] args) throws Exception {
        CountDownLatch drawn = new CountDownLatch(1);
        JFrame[] frame = new JFrame[1];
        SwingUtilities.invokeAndWait(() -> {
            JFrame f = new JFrame("zigsaw swing fixture");
            f.add(new JComponent() {
                @Override protected void paintComponent(Graphics g) {
                    Graphics2D g2 = (Graphics2D) g;
                    g2.setColor(Color.WHITE);
                    g2.fillRect(0, 0, getWidth(), getHeight());
                    g2.setColor(Color.BLACK);
                    new TextLayout("hello from zigsaw", getFont(), g2.getFontRenderContext()).draw(g2, 10, 30);
                    drawn.countDown();
                }
            });
            f.setSize(240, 120);
            f.setDefaultCloseOperation(WindowConstants.DISPOSE_ON_CLOSE);
            f.setVisible(true);
            frame[0] = f;
        });
        boolean ok = drawn.await(30, TimeUnit.SECONDS);
        System.out.println(ok ? "Swing: a window came up and drew its text" : "Swing: nothing drawn in 30 s");
        SwingUtilities.invokeAndWait(() -> frame[0].dispose());
        System.exit(ok ? 0 : 1);
    }
}
