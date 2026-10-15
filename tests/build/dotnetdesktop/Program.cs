using System;

static class Program
{
    // A Windows Forms form and a WPF window, each closing itself once it's
    // up, so that the program shows both frameworks work and then exits.
    [STAThread]
    static int Main()
    {
        var form = new System.Windows.Forms.Form { Text = "zigsaw winforms", Width = 240, Height = 120 };
        form.Shown += (_, _) => form.Close();
        System.Windows.Forms.Application.Run(form);
        Console.WriteLine("Windows Forms: a form came up");

        var app = new System.Windows.Application();
        var window = new System.Windows.Window { Title = "zigsaw wpf", Width = 240, Height = 120, Content = new System.Windows.Controls.TextBlock { Text = "zigsaw" } };
        window.ContentRendered += (_, _) => window.Close();
        app.Run(window);
        Console.WriteLine("WPF: a window came up and drew its content");
        return 0;
    }
}
