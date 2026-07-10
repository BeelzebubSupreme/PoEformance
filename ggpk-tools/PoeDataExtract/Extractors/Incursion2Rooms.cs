using System.Text;
using LibBundle3;
using LibBundle3.Nodes;
using Index = LibBundle3.Index;

namespace PoeDataExtract.Extractors;

/// <summary>
/// Extracts <c>data/incursion2_rooms.tsv</c> from
/// <c>data/balance/incursion2rooms.datc64</c> — the Vaal Ruins (PoE2's
/// reworked Incursion / Temple of Atzoatl) room FAMILY catalog. Feeds the
/// Vaal Ruins Route Planner with the real room list, upgrade graph and
/// flags (previously hand-typed).
///
/// Column layout verified two ways (both agree exactly):
///   - poe-tool-dev/dat-schema: 11 columns in this order.
///   - the tool's own `inspect`: rowSize = 95 bytes.
/// Sizes: string=8, bool=1, row[]/foreignrow[]=16 (count+ptr header),
/// i32=4, foreignrow=16 → 8+1+16+16+16+4+1+1+8+8+16 = 95. ✓
///
///   @0x00  string      Id                (e.g. "Garrison", "Path")
///   @0x08  bool        IsPathway
///   @0x09  row[]       UpgradedBy         → room indices this upgrades into
///   @0x19  row[]       ConvertedBy
///   @0x29  row[]       ConvertedTo        → room indices this converts into
///   @0x39  i32         UpgradedByPower    (tokens/power to upgrade)
///   @0x3D  bool        IsPresentDay
///   @0x3E  bool        IsBossReward
///   @0x3F  string      Name               (display name)
///   @0x47  string      Icon_DDSFile
///   @0x4F  foreignrow  RewardUnlockStat   (→ Stats; ignored here)
///
/// NOTE: there is NO door/connection column in this (or any) incursion
/// table — the physical doorway geometry lives in the .tdt terrain tiles,
/// not the dat. This extractor supplies everything ELSE the planner needs.
///
/// Output TSV (one row per room family):
///   id  is_pathway  is_boss_reward  upgrade_power  upgraded_by  converted_to  name  icon
/// where upgraded_by / converted_to are semicolon-joined room ids.
/// </summary>
internal sealed class Incursion2Rooms : IExtractor
{
    private const int OffId             = 0x00;
    private const int OffIsPathway      = 0x08;
    private const int OffUpgradedBy     = 0x09;
    private const int OffConvertedTo    = 0x29;
    private const int OffUpgradedByPow  = 0x39;
    private const int OffIsBossReward   = 0x3E;
    private const int OffName           = 0x3F;
    private const int OffIcon           = 0x47;

    public void Run(Index index, string outputTsvPath)
    {
        string[] candidates = { "data/balance/incursion2rooms.datc64", "Data/Incursion2Rooms.dat64" };
        FileNode? fileNode = null;
        foreach (var c in candidates)
            if (index.TryFindNode(c, out var node) && node is FileNode fn) { fileNode = fn; break; }
        if (fileNode is null)
            throw new FileNotFoundException(string.Join(" / ", candidates));

        var dat = new DatReader(fileNode.Record.Read().Span);
        Console.Out.WriteLine($"opened {candidates[0]}: rowCount={dat.RowCount} rowSize={dat.RowSize}");

        // Pass 1: index → Id, so the upgrade-graph row refs resolve to ids.
        var ids = new string[dat.RowCount];
        for (int i = 0; i < dat.RowCount; i++)
            ids[i] = dat.RowString(i, OffId);

        // `row`-type arrays store 8-byte row indices per element (self-ref
        // into this same table). Resolve each to its Id, dropping any
        // out-of-range/null sentinel.
        string JoinRooms(int row, int offset)
        {
            var refs = dat.RowArray(row, offset, elementBytes: 8);
            if (refs.Length == 0) return "";
            var parts = new List<string>(refs.Length);
            foreach (var r in refs)
                if (r >= 0 && r < dat.RowCount && !string.IsNullOrEmpty(ids[(int)r]))
                    parts.Add(ids[(int)r]);
            return string.Join(';', parts);
        }

        var sb = new StringBuilder(capacity: dat.RowCount * 96);
        sb.Append("id\tis_pathway\tis_boss_reward\tupgrade_power\tupgraded_by\tconverted_to\tname\ticon\n");
        int written = 0;
        for (int i = 0; i < dat.RowCount; i++)
        {
            string id = ids[i];
            if (string.IsNullOrEmpty(id)) continue;
            string name = dat.RowString(i, OffName);
            string icon = dat.RowString(i, OffIcon);
            bool isPath = dat.RowBool(i, OffIsPathway);
            bool isBoss = dat.RowBool(i, OffIsBossReward);
            int power   = dat.RowI32(i, OffUpgradedByPow);
            string upBy = JoinRooms(i, OffUpgradedBy);
            string conv = JoinRooms(i, OffConvertedTo);

            // Guard the display strings against tab/newline wrecking the TSV.
            name = Clean(name); icon = Clean(icon);
            sb.Append(id).Append('\t')
              .Append(isPath ? '1' : '0').Append('\t')
              .Append(isBoss ? '1' : '0').Append('\t')
              .Append(power).Append('\t')
              .Append(upBy).Append('\t')
              .Append(conv).Append('\t')
              .Append(name).Append('\t')
              .Append(icon).Append('\n');
            written++;
        }

        WriteTsv(outputTsvPath, sb);
        Console.Out.WriteLine($"wrote {written} rows to {outputTsvPath}");
    }

    private static string Clean(string s) =>
        s.Replace('\t', ' ').Replace('\n', ' ').Replace('\r', ' ');

    private static void WriteTsv(string outputTsvPath, StringBuilder sb)
    {
        var dir = Path.GetDirectoryName(outputTsvPath);
        if (!string.IsNullOrEmpty(dir)) Directory.CreateDirectory(dir);
        string tmp = outputTsvPath + ".tmp";
        File.WriteAllText(tmp, sb.ToString(), new UTF8Encoding(encoderShouldEmitUTF8Identifier: false));
        if (File.Exists(outputTsvPath)) File.Delete(outputTsvPath);
        File.Move(tmp, outputTsvPath);
    }
}
