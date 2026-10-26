// A data type as a review reads it (GET /v1/type): its C declaration and, for
// a structure or union, every field with its offset and size, so a definition
// a review wrote can be laid beside the one another review published and
// brought in line in one pass.
//
// The C is what the type holds, not what was written: a field Ghidra left
// undefined is a gap between offsets, never invented, and a structure whose
// size is more than its last field says so in `size`.

import com.google.gson.JsonArray;
import com.google.gson.JsonElement;
import com.google.gson.JsonNull;
import com.google.gson.JsonObject;
import ghidra.program.model.data.Array;
import ghidra.program.model.data.BitFieldDataType;
import ghidra.program.model.data.Composite;
import ghidra.program.model.data.DataType;
import ghidra.program.model.data.DataTypeComponent;
import ghidra.program.model.data.Enum;
import ghidra.program.model.data.FunctionDefinition;
import ghidra.program.model.data.Pointer;
import ghidra.program.model.data.Structure;
import ghidra.program.model.data.TypeDef;
import ghidra.program.model.data.Union;

final class TypeText {
    private TypeText() {}

    /** The type's facts and its C; JSON null for no type. */
    static JsonElement describe(DataType type) {
        if (type == null) return JsonNull.INSTANCE;
        JsonObject answer = new JsonObject();
        answer.addProperty("path", type.getPathName());
        answer.addProperty("kind", kind(type));
        answer.addProperty("size", type.getLength());
        answer.addProperty("c", c(type));
        DataType base = type instanceof TypeDef def ? def.getBaseDataType() : type;
        if (type instanceof TypeDef def) answer.addProperty("base", def.getDataType().getPathName());
        if (base instanceof Composite composite) {
            answer.addProperty("packed", composite.isPackingEnabled());
            answer.addProperty("alignment", composite.getAlignment());
            JsonArray fields = new JsonArray();
            for (DataTypeComponent component : composite.getDefinedComponents()) {
                JsonObject field = new JsonObject();
                field.addProperty("offset", "0x" + Integer.toHexString(component.getOffset()).toUpperCase());
                field.addProperty("size", component.getLength());
                field.addProperty("name", fieldName(component));
                if (component.isBitFieldComponent()) {
                    BitFieldDataType bits = (BitFieldDataType) component.getDataType();
                    field.addProperty("type", bits.getBaseDataType().getDisplayName());
                    field.addProperty("bits", bits.getBitSize());
                    field.addProperty("bit_offset", bits.getBitOffset());
                } else {
                    field.addProperty("type", component.getDataType().getDisplayName());
                }
                if (component.getComment() != null) field.addProperty("comment", component.getComment());
                fields.add(field);
            }
            answer.add("fields", fields);
        } else if (base instanceof Enum values) {
            JsonObject members = new JsonObject();
            for (long value : values.getValues()) {
                for (String name : values.getNames(value)) members.addProperty(name, value);
            }
            answer.add("values", members);
        }
        return answer;
    }

    static String kind(DataType type) {
        if (type instanceof TypeDef) return "typedef";
        if (type instanceof Structure) return "struct";
        if (type instanceof Union) return "union";
        if (type instanceof Enum) return "enum";
        if (type instanceof Pointer) return "pointer";
        if (type instanceof Array) return "array";
        if (type instanceof FunctionDefinition) return "function";
        return "builtin";
    }

    /** The declaration: `typedef struct _X { … } X;` for a typedef of a tagged type. */
    static String c(DataType type) {
        if (type instanceof TypeDef def) {
            DataType base = def.getDataType();
            if (base instanceof Composite || base instanceof Enum) {
                return "typedef " + body(base) + " " + def.getName() + ";";
            }
            return "typedef " + declarator(base, def.getName()) + ";";
        }
        if (type instanceof Composite || type instanceof Enum) return body(type) + ";";
        if (type instanceof FunctionDefinition function) return function.getPrototypeString() + ";";
        return type.getDisplayName();
    }

    private static String body(DataType type) {
        StringBuilder out = new StringBuilder();
        if (type instanceof Enum values) {
            out.append("enum ").append(type.getName()).append(" {\n");
            long[] all = values.getValues();
            java.util.List<String> lines = new java.util.ArrayList<>();
            for (long value : all) {
                for (String name : values.getNames(value)) {
                    lines.add("    " + name + " = 0x" + Long.toHexString(value).toUpperCase());
                }
            }
            out.append(String.join(",\n", lines)).append("\n}");
            return out.toString();
        }
        Composite composite = (Composite) type;
        out.append(composite instanceof Union ? "union " : "struct ").append(type.getName()).append(" {\n");
        for (DataTypeComponent component : composite.getDefinedComponents()) {
            out.append("    /* 0x").append(String.format("%02X", component.getOffset())).append(" */ ");
            if (component.isBitFieldComponent()) {
                BitFieldDataType bits = (BitFieldDataType) component.getDataType();
                out.append(bits.getBaseDataType().getDisplayName()).append(' ').append(fieldName(component))
                   .append(" : ").append(bits.getBitSize());
            } else {
                out.append(declarator(component.getDataType(), fieldName(component)));
            }
            out.append(";");
            if (component.getComment() != null) out.append(" // ").append(component.getComment().replace('\n', ' '));
            out.append('\n');
        }
        out.append("} /* size 0x").append(Integer.toHexString(type.getLength()).toUpperCase()).append(" */");
        return out.toString();
    }

    /** `UINT8 Unknown01[7]` — an array's bounds after the name, outer first. */
    private static String declarator(DataType type, String name) {
        if (type instanceof Array array) {
            return declarator(array.getDataType(), name + "[" + array.getNumElements() + "]");
        }
        return type.getDisplayName() + " " + name;
    }

    private static String fieldName(DataTypeComponent component) {
        String name = component.getFieldName();
        return name != null ? name : component.getDefaultFieldName();
    }
}
