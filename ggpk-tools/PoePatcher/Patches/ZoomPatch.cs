using System.Globalization;
using System.Text;
using System.Text.RegularExpressions;
using LibBundle3;
using Index = LibBundle3.Index;
using LibBundle3.Records;

namespace PoePatcher.Patches;

/// <summary>
/// Zooms the gameplay camera out by injecting a camera-zoom node into the
/// player object template <c>metadata/characters/character.ot</c>.
///
/// RE (verified July 2026 against the KintaroEB zoom .ggpx via a bundle
/// before/after diff): the zoom-out is achieved entirely by adding one line to
/// the SERVER-side <c>Positioned</c> component of character.ot —
/// <code>
///   on_initial_position_set = { CreateCameraZoomNode(1000000000.0f, 1000000000.0f, 1.9f); }
/// </code>
/// The two huge radii mean "apply everywhere"; the third argument is the zoom
/// FACTOR (1.0 ≈ default, higher = further out; the Kintaro presets are
/// 1.3 / 1.6 / 1.9). The clean template has no such line — the Positioned block
/// ends immediately after <c>team = 1</c> — so applying is a single injection and
/// reverting restores the pre-patch bytes verbatim (BackupManager), same model as
/// MinimapPatch. Per-scene camera nodes (boss intros, camerazoom/*.ot) are a
/// separate concern the Kintaro patch also stubs; this covers the general
/// gameplay zoom, which is what character.ot controls.
///
/// character.ot is UTF-16LE WITH a BOM (unlike the UTF-8 shaders MinimapPatch
/// edits), so we decode/encode with <see cref="Encoding.Unicode"/> and keep the
/// leading U+FEFF character intact through the round-trip. The file uses CRLF
/// around the marker.
/// </summary>
internal sealed class ZoomPatch : IPatch
{
    public string Name => "zoom";
    public string Description => "Zoom the gameplay camera out (injects CreateCameraZoomNode into character.ot).";

    private const string TargetPath = "metadata/characters/character.ot";

    // The clean marker: the Positioned block closes right after `team = 1`.
    // Byte-verified against a fresh extraction of character.ot. If a game patch
    // changes the surrounding template this stops matching and Apply fails loud
    // (rather than silently writing an unchanged file), same as MinimapPatch.
    private const string CleanMarker = "team = 1\r\n}";

    /// <summary>Camera zoom factor written as the 3rd CreateCameraZoomNode arg.
    /// 1.0 ≈ default; higher zooms further out. Clamped by the CLI (1.0–3.0).</summary>
    public float ZoomFactor { get; set; } = 1.6f;

    public void Apply(Index index, BackupManager backups)
    {
        var rec = ResolveRecord(index, TargetPath);
        var original = rec.Read();
        backups.Save(Name, TargetPath, original.Span);

        // Keep the leading BOM (U+FEFF) — decoding UTF-16LE bytes that start with
        // FF FE yields it as text[0], and re-encoding emits FF FE again, so the
        // file's BOM survives the round-trip.
        string text = Encoding.Unicode.GetString(original.Span);

        if (!text.Contains(CleanMarker, StringComparison.Ordinal))
            throw new InvalidOperationException(
                $"Zoom marker not found in {TargetPath} — expected a clean, un-patched character.ot. " +
                "Revert any existing zoom first (or the template changed in a game patch).");

        string factor = ZoomFactor.ToString("0.0###", CultureInfo.InvariantCulture);
        string injected =
            "team = 1\r\n\ton_initial_position_set = { CreateCameraZoomNode(1000000000.0f, 1000000000.0f, "
            + factor + "f); } // PoEformance zoom\r\n}";

        // First occurrence only (team=1 is in the top-level Positioned block).
        int at = text.IndexOf(CleanMarker, StringComparison.Ordinal);
        text = text[..at] + injected + text[(at + CleanMarker.Length)..];

        rec.Write(Encoding.Unicode.GetBytes(text));

        // Stub the per-scene camerazoom nodes so they stop fighting the general
        // zoom (the "camera pulses between default and the zoom factor" bug). Each
        // is a small .ot with a CreateCameraZoomNode(inner, outer, factor); we set
        // the FACTOR to the same value (radii kept) so, wherever one is active, it
        // matches the character.ot zoom instead of overriding it. Mirrors the
        // KintaroEB patch, which sets every touched file to the chosen factor
        // (its zoom13/16/19 presets are byte-identical in size — same files, only
        // the factor differs). Best-effort: files without the call are skipped.
        StubSceneCameraZooms(index, backups, factor);
    }

    // CreateCameraZoomNode(inner, outer, factor). The scene files use plain floats
    // (no 'f' suffix, unlike the character.ot injection), e.g.
    // "CreateCameraZoomNode(4.0, 10.0, 0.75)". Capture the two radii, replace only
    // the factor.
    private static readonly Regex ZoomNodeRe = new(
        @"CreateCameraZoomNode\(\s*([-\d.]+)\s*,\s*([-\d.]+)\s*,\s*([-\d.]+)\s*\)",
        RegexOptions.Compiled);

    // A camerazoom scene node lives at a path containing "camerazoom" ending in
    // ".ot" (the miscellaneousobjects/camerazoom/* family + a few terrain ones).
    private static bool IsSceneCameraZoom(string? path)
        => path is not null
        && path.IndexOf("camerazoom", StringComparison.OrdinalIgnoreCase) >= 0
        && path.EndsWith(".ot", StringComparison.OrdinalIgnoreCase)
        && !string.Equals(path, TargetPath, StringComparison.OrdinalIgnoreCase);

    private void StubSceneCameraZooms(Index index, BackupManager backups, string factor)
    {
        // Collect first (don't mutate bundle records mid-enumeration of Files).
        var targets = new List<FileRecord>();
        foreach (var kv in index.Files)
            if (kv.Value is FileRecord fr && IsSceneCameraZoom(fr.Path))
                targets.Add(fr);

        foreach (var r in targets)
        {
            var orig = r.Read();
            string t = Encoding.Unicode.GetString(orig.Span);   // UTF-16LE + BOM, like character.ot
            if (!ZoomNodeRe.IsMatch(t))
                continue;
            string patched = ZoomNodeRe.Replace(t, m =>
                $"CreateCameraZoomNode({m.Groups[1].Value}, {m.Groups[2].Value}, {factor})");
            if (patched == t)
                continue;   // already at the target factor
            backups.Save(Name, r.Path, orig.Span);
            r.Write(Encoding.Unicode.GetBytes(patched));
        }
    }

    public void Revert(Index index, BackupManager backups)
    {
        // Primary file first.
        var rec = ResolveRecord(index, TargetPath);
        rec.Write(backups.Load(Name, TargetPath));

        // Restore any per-scene camerazoom files this patch modified (TryLoad =
        // only the ones we actually backed up).
        var targets = new List<FileRecord>();
        foreach (var kv in index.Files)
            if (kv.Value is FileRecord fr && IsSceneCameraZoom(fr.Path))
                targets.Add(fr);
        foreach (var r in targets)
        {
            var bak = backups.TryLoad(Name, r.Path);
            if (bak != null)
                r.Write(bak);
        }

        backups.Clear(Name);
    }

    /// <summary>
    /// Resolves a file record by path. Uses the flat <see cref="Index.Files"/>
    /// map rather than <c>TryFindNode</c> — the node-tree walk misses some paths
    /// (character.ot among them) that the flat record map resolves fine.
    /// Case-insensitive to match the path form the manifest prints.
    /// </summary>
    private static FileRecord ResolveRecord(Index index, string path)
    {
        foreach (var kv in index.Files)
            if (kv.Value is FileRecord fr && string.Equals(fr.Path, path, StringComparison.OrdinalIgnoreCase))
                return fr;
        throw new FileNotFoundException(path);
    }
}
