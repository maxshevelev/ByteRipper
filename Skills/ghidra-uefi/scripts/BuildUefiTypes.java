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
//
// After the parse, two integer types become enums, so the decompiler prints
// `EFI_INVALID_PARAMETER` where it printed `0x80000002`. EDK2 spells their
// values as `#define`s, which the parser keeps — each as a one-value enum
// `define_<NAME>` under `/<header>/defines` — but ties to no type. A change
// here is a change of every typed analysis: raise `TYPES_REVISION` in
// `uefi_types.py` and `UEFITypes.swift` with it.
// @category ByteRipper

import java.io.File;
import java.util.ArrayList;
import java.util.List;

import ghidra.app.script.GhidraScript;
import ghidra.app.util.cparser.C.CParserUtils;
import ghidra.program.model.data.Category;
import ghidra.program.model.data.CategoryPath;
import ghidra.program.model.data.DataType;
import ghidra.program.model.data.EnumDataType;
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
        int transaction = types.startTransaction("value sets");
        try {
            statusEnum(types);
            statusCodeTypeEnum(types);
        } finally {
            types.endTransaction(transaction, true);
        }
        println("wrote " + types.getDataTypeCount(true) + " types to " + archive);
        types.save();
        types.close();
    }

    /** The value of `#define name`, as the parser kept it, or null. */
    private static Long define(FileDataTypeManager types, String header, String name) {
        DataType type = types.getDataType(new CategoryPath("/" + header + "/defines"), "define_" + name);
        if (!(type instanceof ghidra.program.model.data.Enum)) {
            return null;
        }
        ghidra.program.model.data.Enum value = (ghidra.program.model.data.Enum) type;
        String[] names = value.getNames();
        return names.length == 1 ? value.getValue(names[0]) : null;
    }

    /**
     * `EFI_STATUS` as an enum of the codes EDK2 gives it, the width of the
     * archive's `UINTN`. The codes are the ones `Base.h` defines as
     * `RETURN_<NAME>` and `UefiBaseType.h` renames `EFI_<NAME>` — how EDK2
     * itself declares them — so a `#define` that only starts with `EFI_` is
     * not taken for a status. `RETURN_STATUS` stays an integer.
     */
    private void statusEnum(FileDataTypeManager types) throws Exception {
        CategoryPath category = new CategoryPath("/UefiBaseType.h");
        DataType status = types.getDataType(category, "EFI_STATUS");
        if (status == null) {
            throw new IllegalStateException("EFI_STATUS is not in the archive");
        }
        Category defines = types.getCategory(new CategoryPath("/Base.h/defines"));
        if (defines == null) {
            throw new IllegalStateException("Base.h's defines are not in the archive");
        }
        List<String> codes = new ArrayList<>();
        for (DataType define : defines.getDataTypes()) {
            String name = define.getName();
            if (name.startsWith("define_RETURN_")) {
                codes.add(name.substring("define_RETURN_".length()));
            }
        }
        codes.sort(null);
        EnumDataType values = new EnumDataType(category, "EFI_STATUS", status.getLength(), types);
        values.setDescription("EFI_STATUS: the codes of UefiBaseType.h (RETURN_* of Base.h)");
        int added = 0;
        for (String code : codes) {
            Long value = define(types, "UefiBaseType.h", "EFI_" + code);
            Long base = define(types, "Base.h", "RETURN_" + code);
            if (value == null || !value.equals(base)) {
                continue;
            }
            values.add("EFI_" + code, value);
            added++;
        }
        if (added < 30) {
            throw new IllegalStateException("only " + added + " EFI_STATUS codes found");
        }
        types.replaceDataType(status, values, true);
        println("EFI_STATUS: " + added + " codes, " + status.getLength() + " bytes");
    }

    /**
     * `EFI_STATUS_CODE_TYPE` (`PiStatusCode.h`): the kind of a report in its
     * low byte and, for an error, its severity in the high one. The decompiler
     * writes a value that is no member as the members it is made of, which is
     * how the type is read: `EFI_ERROR_MAJOR|EFI_ERROR_CODE`. Its masks are
     * left out, or they would be what a value is made of. The value
     * (`EFI_STATUS_CODE_VALUE`) stays an integer: its operations repeat
     * between subclasses, and a composition of them would be a guess.
     */
    private void statusCodeTypeEnum(FileDataTypeManager types) throws Exception {
        CategoryPath category = new CategoryPath("/PiStatusCode.h");
        DataType type = types.getDataType(category, "EFI_STATUS_CODE_TYPE");
        if (type == null) {
            throw new IllegalStateException("EFI_STATUS_CODE_TYPE is not in the archive");
        }
        String[] names = {
            "EFI_PROGRESS_CODE", "EFI_ERROR_CODE", "EFI_DEBUG_CODE",
            "EFI_ERROR_MINOR", "EFI_ERROR_MAJOR", "EFI_ERROR_UNRECOVERED", "EFI_ERROR_UNCONTAINED",
        };
        EnumDataType values = new EnumDataType(category, "EFI_STATUS_CODE_TYPE", type.getLength(), types);
        values.setDescription("EFI_STATUS_CODE_TYPE: report kind | error severity (PiStatusCode.h)");
        for (String name : names) {
            Long value = define(types, "PiStatusCode.h", name);
            if (value == null) {
                throw new IllegalStateException(name + " is not in the archive");
            }
            values.add(name, value);
        }
        types.replaceDataType(type, values, true);
        println("EFI_STATUS_CODE_TYPE: " + names.length + " values");
    }
}
