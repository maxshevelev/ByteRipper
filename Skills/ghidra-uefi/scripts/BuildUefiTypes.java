// Build the UEFI data type archives the UEFI pass types a module with.
//
//   analyzeHeadless <project> <name> -import <any file> -noanalysis \
//       -deleteProject -preScript BuildUefiTypes.java <edk2> <out-dir>
//
// Ghidra ships the means but not the archives: its own
// CreateUEFIGDTArchivesScript reads a fixed path and asks for a folder. This is
// the same parse — Ghidra's C parser over MdePkg's headers, the PI and UEFI
// specs, every PPI and protocol — with the paths as arguments, for the two
// processors a PC firmware runs: `uefi_X64.gdt` and `uefi_Ia32.gdt` in
// <out-dir>. The program the headless run imports is not touched; a script
// needs one to run.
//
// <edk2> is a checkout whose MdePkg/Include is present (a sparse clone of a
// tagged `edk2-stable` release is enough; `uefi_types.py` makes one).
// @category ByteRipper

import java.io.File;

import ghidra.app.script.GhidraScript;
import ghidra.app.util.cparser.C.CParserUtils;
import ghidra.program.model.data.FileDataTypeManager;

public class BuildUefiTypes extends GhidraScript {

    @Override
    public void run() throws Exception {
        String[] args = getScriptArgs();
        if (args.length < 2) {
            println("usage: BuildUefiTypes.java <edk2> <out-dir>");
            return;
        }
        String include = new File(args[0], "MdePkg/Include").getAbsolutePath();
        File out = new File(args[1]);
        out.mkdirs();
        build(include, out, "X64", "x86:LE:64:default");
        build(include, out, "Ia32", "x86:LE:32:default");
    }

    private void build(String include, File out, String processor, String language)
            throws Exception {
        String[] files = {
            "ProcessorBind.h",
            "Uefi/UefiBaseType.h",
            "Uefi/UefiSpec.h",
            "PiDxe.h",
            "PiMm.h",
            "PiPei.h",
            "PiSmm.h",
            "Library/PeimEntryPoint.h",
            "Library/UefiDriverEntryPoint.h",
            include + "/Pi/",
            include + "/Ppi/",
            include + "/Protocol/",
            include + "/IndustryStandard/",
        };
        String[] includePaths = { include + "/" + processor, include };
        String[] cppArgs = { "-DSTATIC_ASSERT=static_assert" };

        File archive = new File(out, "uefi_" + processor + ".gdt");
        archive.delete();
        new File(archive.getPath() + ".ulock").delete();
        FileDataTypeManager types = CParserUtils.parseHeaderFiles(null, files, includePaths,
            cppArgs, archive.getAbsolutePath(), language, "windows", monitor);
        println("wrote " + types.getDataTypeCount(true) + " types to " + archive);
        types.save();
        types.close();
    }
}
