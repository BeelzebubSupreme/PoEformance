using System.Text;
using LibBundle3;
using LibBundle3.Nodes;
using Index = LibBundle3.Index;

namespace PoeDataExtract.Extractors;

/// <summary>
/// Extracts <c>data/incursion2_room_levels.tsv</c> from
/// <c>data/balance/incursion2roomperlevel.datc64</c> — the per-tier Vaal
/// Ruins room INSTANCES (e.g. garrison_lvl1 "Guardhouse" → lvl2 "Barracks"
/// → lvl3 "Hall of War"), with the reward mod magnitudes. Gives the planner
/// the real upgrade-tier names + reward values per room.
///
/// Column layout verified two ways (agree exactly):
///   - poe-tool-dev/dat-schema: 9 columns in this order.
///   - the tool's own `inspect`: rowSize = 92 bytes.
/// Sizes: foreignrow=16, i32=4, string=8, i32[]=16 →
///        16+4+8+8+8+8+16+16+8 = 92. ✓
///
///   @0x00  foreignrow  Room          (→ Incursion2Rooms family index)
///   @0x10  i32         Level         (tier: 1..4)
///   @0x14  string      Id            ("garrison_lvl1")
///   @0x1C  string      Description
///   @0x24  string      Name          ("Guardhouse")
///   @0x2C  string      Icon_DDSFile
///   @0x34  foreignrow  Mod           (→ Mods; index only here)
///   @0x44  i32[]       ModValues     (reward magnitudes)
///   @0x54  string      Description2
///
/// Output TSV (one row per room tier):
///   id  room_index  level  name  description  mod_values
/// where mod_values is a semicolon-joined int list.
/// </summary>
internal sealed class Incursion2RoomPerLevel : IExtractor
{
    private const int OffRoom        = 0x00;
    private const int OffLevel       = 0x10;
    private const int OffId          = 0x14;
    private const int OffDescription = 0x1C;
    private const int OffName        = 0x24;
    private const int OffModValues   = 0x44;

    public void Run(Index index, string outputTsvPath)
    {
        string[] candidates = { "data/balance/incursion2roomperlevel.datc64", "Data/Incursion2RoomPerLevel.dat64" };
        FileNode? fileNode = null;
        foreach (var c in candidates)
            if (index.TryFindNode(c, out var node) && node is FileNode fn) { fileNode = fn; break; }
        if (fileNode is null)
            throw new FileNotFoundException(string.Join(" / ", candidates));

        var dat = new DatReader(fileNode.Record.Read().Span);
        Console.Out.WriteLine($"opened {candidates[0]}: rowCount={dat.RowCount} rowSize={dat.RowSize}");

        var sb = new StringBuilder(capacity: dat.RowCount * 96);
        sb.Append("id\troom_index\tlevel\tname\tdescription\tmod_values\n");
        int written = 0;
        for (int i = 0; i < dat.RowCount; i++)
        {
            string id = dat.RowString(i, OffId);
            if (string.IsNullOrEmpty(id)) continue;
            long room = dat.RowFk(i, OffRoom);
            int level = dat.RowI32(i, OffLevel);
            string name = Clean(dat.RowString(i, OffName));
            string desc = Clean(dat.RowString(i, OffDescription));
            // ModValues is a plain i32[] (4-byte elements) — use the dedicated
            // 4-byte array reader (RowArray reads 8 bytes/element and would
            // return -1 sentinels for packed int32 arrays).
            var mv = dat.RowI32Array(i, OffModValues);
            string modValues = mv.Length == 0 ? "" : string.Join(';', mv);

            sb.Append(id).Append('\t')
              .Append(room).Append('\t')
              .Append(level).Append('\t')
              .Append(name).Append('\t')
              .Append(desc).Append('\t')
              .Append(modValues).Append('\n');
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
