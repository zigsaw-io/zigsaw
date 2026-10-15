using System.Runtime.InteropServices;
using Humanizer;

// Says which .NET runs it, and where from (the runtime image's directory),
// with a string from its NuGet package.
var name = args.Length > 0 ? args[0] : "world";
Console.WriteLine($"hello, {name}, from .NET {Environment.Version}");
Console.WriteLine("built_with_a_vendored_package".Humanize(LetterCasing.Sentence));
Console.WriteLine($"runs on {RuntimeEnvironment.GetRuntimeDirectory()}");
