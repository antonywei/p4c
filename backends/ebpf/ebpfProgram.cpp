/*
Copyright 2013-present Barefoot Networks, Inc.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/

#include <chrono>
#include <ctime>

#include "ebpfProgram.h"
#include "ebpfType.h"
#include "ebpfControl.h"
#include "ebpfParser.h"
#include "ebpfTable.h"
#include "frontends/p4/coreLibrary.h"
#include "frontends/common/options.h"

namespace EBPF {

bool EBPFProgram::build() {
    auto pack = toplevel->getMain();
    if (pack->getConstructorParameters()->size() != 2) {
        ::error("Expected toplevel package %1% to have 2 parameters", pack->type);
        return false;
    }

    auto pb = pack->getParameterValue(model.filter.parser.name)
                      ->to<IR::ParserBlock>();
    BUG_CHECK(pb != nullptr, "No parser block found");
    parser = new EBPFParser(this, pb, typeMap);
    bool success = parser->build();
    if (!success)
        return success;

    auto cb = pack->getParameterValue(model.filter.filter.name)
                      ->to<IR::ControlBlock>();
    BUG_CHECK(cb != nullptr, "No control block found");
    control = new EBPFControl(this, cb, parser->headers);
    success = control->build();
    if (!success)
        return success;

    return true;
}

void EBPFProgram::emitC(CodeBuilder* builder, cstring header) {
    emitGeneratedComment(builder);

    // Find the last occurrence of a folder slash (Linux only)
    const char* header_stripped = header.findlast('/');
    if (header_stripped)
        // Remove the path from the header
        builder->appendFormat("#include \"%s\"", header_stripped + 1);
    else
        // There is no prepended path, just include the header
        builder->appendFormat("#include \"%s\"", header);
    builder->newline();

    builder->target->emitIncludes(builder);
    emitPreamble(builder);
    builder->append("REGISTER_START()\n");
    control->emitTableInstances(builder);
    builder->append("REGISTER_END()\n");
    builder->newline();
    builder->emitIndent();
    builder->target->emitCodeSection(builder, functionName);
    builder->emitIndent();
    builder->target->emitMain(builder, functionName, model.CPacketName.str());
    builder->blockStart();

    emitHeaderInstances(builder);
    builder->append(" = ");
    parser->headerType->emitInitializer(builder);
    builder->endOfStatement(true);

    // HACK to force LLVM to put the headers on the stack.
    // This should not be needed, but the llvm bpf back-end seems to be broken.
    // builder->emitIndent();
    // builder->append("printk(\"%p\", ");
    // builder->append(parser->headers->name);
    // builder->append(")");
    // builder->endOfStatement(true);
    emitLocalVariables(builder);
    builder->newline();
    builder->emitIndent();
    builder->appendFormat("goto %s;", IR::ParserState::start.c_str());
    builder->newline();

    parser->emit(builder);
    emitPipeline(builder);

    builder->emitIndent();
    builder->append(endLabel);
    builder->appendLine(":");
    builder->emitIndent();
    builder->append("return ");
    builder->append(control->accept->name.name);
    builder->appendLine(";");
    builder->blockEnd(true);  // end of function

    builder->target->emitLicense(builder, license);
}

void EBPFProgram::emitGeneratedComment(CodeBuilder* builder) {
    std::chrono::time_point<std::chrono::system_clock> now = std::chrono::system_clock::now();
    std::time_t time = std::chrono::system_clock::to_time_t(now);
    builder->append("/* Automatically generated by ");
    builder->append(options.exe_name);
    builder->append(" from ");
    builder->append(options.file);
    builder->append(" on ");
    builder->append(std::ctime(&time));
    builder->append(" */");
    builder->newline();
}

void EBPFProgram::emitH(CodeBuilder* builder, cstring) {
    emitGeneratedComment(builder);
    builder->appendLine("#ifndef _P4_GEN_HEADER_");
    builder->appendLine("#define _P4_GEN_HEADER_");
    builder->target->emitIncludes(builder);
    builder->appendFormat("#define MAP_PATH \"%s\"", builder->target->sysMapPath().c_str());
    builder->newline();
    emitTypes(builder);
    control->emitTableTypes(builder);
    builder->appendLine("#if CONTROL_PLANE");
    builder->appendLine("static void initialize_tables() ");
    builder->blockStart();
    builder->emitIndent();
    builder->appendFormat("u32 %s = 0;", zeroKey.c_str());
    builder->newline();
    control->emitTableInitializers(builder);
    builder->blockEnd(true);
    builder->appendLine("#endif");
    builder->appendLine("#endif");
}

void EBPFProgram::emitTypes(CodeBuilder* builder) {
    for (auto d : program->declarations) {
        if (d->is<IR::Type>() && !d->is<IR::IContainer>() &&
            !d->is<IR::Type_Extern>() && !d->is<IR::Type_Parser>() &&
            !d->is<IR::Type_Control>() && !d->is<IR::Type_Typedef>() &&
            !d->is<IR::Type_Error>()) {
            auto type = EBPFTypeFactory::instance->create(d->to<IR::Type>());
            if (type == nullptr)
                continue;
            type->emit(builder);
            builder->newline();
        }
    }
}

namespace {
class ErrorCodesVisitor : public Inspector {
    CodeBuilder* builder;
 public:
    explicit ErrorCodesVisitor(CodeBuilder* builder) : builder(builder) {}
    bool preorder(const IR::Type_Error* errors) override {
        for (auto m : *errors->getDeclarations()) {
            builder->emitIndent();
            builder->appendFormat("%s,\n", m->getName().name.c_str());
        }
        return false;
    }
};
}  // namespace

void EBPFProgram::emitPreamble(CodeBuilder* builder) {
    builder->emitIndent();
    builder->appendFormat("enum %s ", errorEnum.c_str());
    builder->blockStart();

    ErrorCodesVisitor visitor(builder);
    program->apply(visitor);

    builder->blockEnd(false);
    builder->endOfStatement(true);
    builder->newline();
    builder->appendLine("#define EBPF_MASK(t, w) ((((t)(1)) << (w)) - (t)1)");
    builder->appendLine("#define BYTES(w) ((w) / 8)");
    builder->appendLine(
        "#define write_partial(a, s, v) do "
        "{ u8 mask = EBPF_MASK(u8, s); "
        "*((u8*)a) = ((*((u8*)a)) & ~mask) | (((v) >> (8 - (s))) & mask); "
        "} while (0)");
    builder->appendLine("#define write_byte(base, offset, v) do { "
                        "*(u8*)((base) + (offset)) = (v); "
                        "} while (0)");
    builder->newline();
    builder->appendLine("void* memcpy(void* dest, const void* src, size_t num);");
    builder->newline();
}

void EBPFProgram::emitLocalVariables(CodeBuilder* builder) {
    builder->emitIndent();
    builder->appendFormat("unsigned %s = 0;", offsetVar);
    builder->newline();

    builder->emitIndent();
    builder->appendFormat("enum %s %s = %s;", errorEnum, errorVar,
                          P4::P4CoreLibrary::instance.noError.str());
    builder->newline();

    builder->emitIndent();
    builder->appendFormat("void* %s = %s;",
                          packetStartVar, builder->target->dataOffset(model.CPacketName.str()));
    builder->newline();
    builder->emitIndent();
    builder->appendFormat("void* %s = %s;",
                          packetEndVar, builder->target->dataEnd(model.CPacketName.str()));
    builder->newline();

    builder->emitIndent();
    builder->appendFormat("u8 %s = 0;", control->accept->name.name);
    builder->newline();

    builder->emitIndent();
    builder->appendFormat("u32 %s = 0;", zeroKey);
    builder->newline();

    builder->emitIndent();
    builder->appendFormat("unsigned char %s;", byteVar);
    builder->newline();
}

void EBPFProgram::emitHeaderInstances(CodeBuilder* builder) {
    builder->emitIndent();
    parser->headerType->declare(builder, parser->headers->name.name, false);
}

void EBPFProgram::emitPipeline(CodeBuilder* builder) {
    builder->emitIndent();
    builder->append(IR::ParserState::accept);
    builder->append(":");
    builder->newline();
    builder->emitIndent();
    builder->blockStart();
    control->emit(builder);
    builder->blockEnd(true);
}

}  // namespace EBPF
