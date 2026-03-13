---
name: swc-parser
description: Parse JavaScript/TypeScript code into AST using SWC (Speedy Web Compiler). Use this for code analysis, transformation, or understanding JavaScript/TypeScript structure.
---

# SWC Parser Tool

SWC (Speedy Web Compiler) is a super-fast TypeScript/JavaScript compiler written in Rust. It can be used to parse JS/TS code into an Abstract Syntax Tree (AST).

## Architecture

```mermaid
graph TB
    subgraph Input["Input"]
        Code[TypeScript/JavaScript Code]
        Args[JSON Arguments]
    end

    subgraph Process["SWC Pipeline"]
        Write[Write to temp file]
        Parse[SWC Parser]
        Output[JSON AST Output]
    end

    Code --> Write
    Args --> Parse
    Write --> Parse
    Parse --> Output
```

## SWC Tool Flow

```mermaid
sequenceDiagram
    participant Agent
    participant SwcTool
    participant FileSystem
    participant SWC
    participant Node

    Agent->>SwcTool: execute(code, type)
    SwcTool->>FileSystem: Write temp file
    SwcTool->>Node: npx swc
    Node->>SWC: Parse with SWC
    SWC-->>Node: AST JSON
    Node-->>SwcTool: AST JSON
    SwcTool-->>Agent: Return AST
```

## AST Structure

```mermaid
graph TB
    Root["File (root)"]
    Prog["Program"]
    Body["Body[]"]
    Decl["VariableDeclaration"]
    Declr["VariableDeclarator"]
    Id["Identifier"]
    Init["NumericLiteral"]

    Root --> Prog
    Prog --> Body
    Body --> Decl
    Decl --> Declr
    Declr --> Id
    Declr --> Init

    style Root fill:#f9f,stroke:#333
    style Prog fill:#bbf,stroke:#333
    style Body fill:#bbf,stroke:#333
    style Decl fill:#dfd,stroke:#333
```

## Example Usage

### TypeScript

```
Thought: I need to analyze the TypeScript code structure.
Action: parse_typescript
Action Input: {"code": "function add(a: number, b: number): number { return a + b; }", "type": "ts"}
Observation: {"type":"File","span":{"start":0,"end":51,"ctxt":0},"body":[{"type":"FunctionDeclaration"...}
```

### JavaScript

```
Thought: I need to analyze the JavaScript code structure.
Action: parse_typescript
Action Input: {"code": "const x = (a, b) => a + b;", "type": "js"}
Observation: {"type":"File","span":{"start":0,"end":26,"ctxt":0},"body":[{"type":"VariableDeclaration"...}
```

## AST Node Types

```mermaid
graph LR
    Declaration[Declaration] --> FunctionDecl[FunctionDeclaration]
    Declaration --> VarDecl[VariableDeclaration]
    Declaration --> ClassDecl[ClassDeclaration]
    
    Expression[Expression] --> Identifier[Identifier]
    Expression --> Literal[Literal]
    Expression --> BinaryOp[BinaryExpression]
    Expression --> ArrowFn[ArrowFunctionExpression]
    
    Statement[Statement] --> IfStmt[IfStatement]
    Statement --> ForStmt[ForStatement]
    Statement --> ReturnStmt[ReturnStatement]
```

## Use Cases

```mermaid
graph LR
    Analysis[Code Analysis] --> FindFuncs[Find Functions]
    Analysis --> FindVars[Find Variables]
    Analysis --> FindImports[Find Imports]
    
    Transform[Code Transform] --> Rename[Rename Refactoring]
    Transform --> Extract[Extract Method]
    Transform --> Inline[Inline Variable]
    
    Generate[Code Generation] --> Minify[Minify]
    Generate --> Transpile[Transpile to ES5]
    Generate --> Bundle[Bundle]
```

- **Code Analysis**: Understand code structure
- **Refactoring**: Find all function calls, variables
- **Linting**: Analyze code patterns
- **Code Generation**: Transform AST to modify code
- **Documentation**: Extract function signatures

## Files

| File | Description |
|------|-------------|
| `libs/agent/src/agent/swc.zig` | SWC tool implementation |
| `.agents/skills/swc-parser/SKILL.md` | This documentation |

## Integration

The SWC tool is available in the agent's tool registry:

```zig
const swc = @import("swc.zig");
const tool = swc.SwcTool{};
try registry.register(.{
    .name = tool.name,
    .description = tool.description,
    .parameters = tool.parameters,
    .execute = tool.execute,
});
```

## Benefits

- **Fast**: Written in Rust, 20-70x faster than Babel
- **Accurate**: Produces correct ESTree-compatible AST
- **TypeScript**: Native TypeScript support
- **Transforms**: Can also minify, transpile, and transform code

## Testing

```bash
zig test libs/agent/src/agent/swc.zig
```

Tests:
- `SwcTool: tool metadata` - Verify tool name, description
- `SwcTool: parseAstNode with valid JSON` - Parse valid AST
- `SwcTool: parseAstNode with invalid JSON` - Handle errors
- `SwcTool: parseAstNode with missing type` - Handle missing fields
