# MiniMax Coding Plan Configuration for SatiCode

This guide explains how to configure SatiCode with MiniMax's Coding Plan for optimal performance.

## Quick Setup

### 1. Subscribe to MiniMax Coding Plan

Visit [MiniMax Coding Plan](https://platform.minimax.io/subscribe/coding-plan) and choose a plan:

- **Starter** - Basic usage
- **Plus** - Enhanced features  
- **Max** - Maximum capabilities

### 2. Get Your API Key

1. Go to [API Keys > Create Coding Plan Key](https://platform.minimax.io/user-center/basic-information/interface-key)
2. Create a new **Coding Plan Key**
3. **Important**: This key is different from pay-as-you-go keys and only works with text models

### 3. Configure Environment Variables

```bash
# Set your MiniMax API key
export MINIMAX_API_KEY="your_api_key_here"

# Optional: Set base URL (included in config but shown for reference)
export ANTHROPIC_BASE_URL="https://api.minimax.io/anthropic"
```

### 4. SatiCode Configuration

Create or update `.saticode.jsonc`:

```jsonc
{
  "$schema": "https://satibot.github.io/saticode/config.json",
  "model": "MiniMax-M2.5",
  "providers": {
    "minimax": {
      "apiKey": "${MINIMAX_API_KEY}",
      "apiBase": "https://api.minimax.io/anthropic"
    }
  },
  "systemPrompt": "You are SatiCode, an expert software engineer powered by MiniMax M2.5. You excel at coding tasks, debugging, architecture design, and providing clear explanations. Help users efficiently and professionally with their development needs."
}
```

## MiniMax M2.5 Features

### **Key Capabilities**

- **Anthropic API Compatible**: Uses standard Anthropic SDK/API
- **Text Models Only**: Optimized for text-based coding tasks
- **Thinking Blocks**: Shows reasoning process for better transparency
- **High Performance**: Fast response times for coding assistance

### **Best Practices**

1. **System Prompts**: Leverage MiniMax's coding expertise with targeted prompts
2. **Context Management**: Use appropriate `maxHistory` settings (50-100 messages)
3. **Error Handling**: MiniMax provides detailed error messages for debugging

## Advanced Configuration

### **Multiple Providers Setup**

```jsonc
{
  "model": "MiniMax-M2.5",
  "providers": {
    "minimax": {
      "apiKey": "${MINIMAX_API_KEY}",
      "apiBase": "https://api.minimax.io/anthropic"
    },
    "openrouter": {
      "apiKey": "${OPENROUTER_API_KEY}"
    }
  }
}
```

### **RAG Optimization**

```jsonc
{
  "rag": {
    "enabled": true,
    "maxHistory": 75,
    "embeddingsModel": "local"
  }
}
```

### **Web Search Integration**

MiniMax Coding Plan includes MCP (Model Context Protocol) for web search:

```jsonc
{
  "tools": {
    "web": {
      "search": {
        "apiKey": "${MINIMAX_API_KEY}",
        "engine": "minimax"
      }
    }
  }
}
```

## Environment Setup

### **Development Environment**

```bash
# Add to your shell profile (.bashrc, .zshrc, etc.)
export MINIMAX_API_KEY="your_api_key_here"

# Verify setup
echo $MINIMAX_API_KEY
```

### **Testing Configuration**

```bash
# Test SatiCode with MiniMax
./saticode-build.sh run

# Or using Bun
bun run dev
```

## Troubleshooting

### **Common Issues**

1. **Invalid API Key**
   - Ensure you're using a **Coding Plan Key**, not pay-as-you-go
   - Check subscription is active

2. **Model Not Found**
   - Verify exact model name: `MiniMax-M2.5`
   - Check API base URL: `https://api.minimax.io/anthropic`

3. **Rate Limiting**
   - Coding Plan has generous limits but monitor usage
   - Consider upgrading plan if needed

### **Debug Mode**

Enable verbose logging for troubleshooting:

```bash
# Debug build
./saticode-build.sh dev

# Or with Bun
ZIG_BUILD_VERBOSE=true bun run dev
```

## Performance Tips

### **Optimal Settings**

```jsonc
{
  "rag": {
    "enabled": true,
    "maxHistory": 50  // Balance context and performance
  },
  "model": "MiniMax-M2.5"  // Use the latest model
}
```

### **Caching**

- SatiCode automatically caches responses when possible
- Local embeddings model reduces API calls for RAG

## Integration Examples

### **VS Code Integration**

```bash
# Install SatiCode globally
make -f Makefile.bun install

# Use in VS Code terminal
saticode
```

### **CI/CD Pipeline**

```yaml
# GitHub Actions example
- name: Setup SatiCode
  run: |
    echo "MINIMAX_API_KEY=${{ secrets.MINIMAX_API_KEY }}" >> $GITHUB_ENV
    bun install
    bun run build
```

## Support

- **MiniMax Platform**: <https://platform.minimax.io>
- **Documentation**: <https://platform.minimax.io/docs/llms.txt>
- **SatiCode Issues**: Check GitHub repository

## Next Steps

1. ✅ Subscribe to MiniMax Coding Plan
2. ✅ Get API key and configure environment
3. ✅ Update `.saticode.jsonc` configuration
4. ✅ Test with `./saticode-build.sh run`
5. 🚀 Start coding with MiniMax M2.5 powered SatiCode!

---

*This configuration leverages MiniMax's Coding Plan for optimal AI-assisted development experience.*
