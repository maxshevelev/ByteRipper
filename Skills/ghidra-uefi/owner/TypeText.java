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
import ghidra.program.model.data.PackingType;
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
        String description = type.getDescription();
        if ((description == null || description.isEmpty()) && type instanceof TypeDef def) {
            description = def.getBaseDataType().getDescription();
        }
        if (description != null && !description.isEmpty()) answer.addProperty("description", description);
        DataType base = type instanceof TypeDef def ? def.getBaseDataType() : type;
        if (type instanceof TypeDef def) answer.addProperty("base", def.getDataType().getPathName());
        if (base instanceof Composite composite) {
            // Not `isPackingEnabled`: Ghidra enables its alignment machinery
            // for a default structure too, and that reads as "packed". The
            // packing type says what the C asked for; a value is there only
            // when it asked explicitly, as `#pragma pack(1)` does.
            PackingType packing = composite.getPackingType();
            answer.addProperty("packing", packing.name().toLowerCase(java.util.Locale.ROOT));
            if (packing == PackingType.EXPLICIT) {
                answer.addProperty("packing_value", composite.getExplicitPackingValue());
            }
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
            JsonObject comments = new JsonObject();
            for (long value : values.getValues()) {
                for (String name : values.getNames(value)) {
                    members.addProperty(name, value);
                    String comment = values.getComment(name);
                    if (comment != null && !comment.isEmpty()) comments.addProperty(name, comment);
                }
            }
            answer.add("values", members);
            if (comments.size() > 0) answer.add("comments", comments);
        }
        return answer;
    }

    static String kind(DataType type) {
        return ExportCode.typeKind(type);
    }

    /** The declaration, as the artifact writes it (`ExportCode.typeC`). */
    static String c(DataType type) {
        return ExportCode.typeC(type);
    }

    private static String fieldName(DataTypeComponent component) {
        return ExportCode.fieldName(component);
    }
}
