# Security Guide

This document outlines security considerations, risks, and best practices for using the satibot framework safely.

## ⚠️ Important Security Notice

**satibot is an AI agent framework with file system access capabilities.** While built-in security restrictions are in place, users must understand the security implications before deploying in production environments.

## 🔒 Security Features

### Built-in Protections

The `readFile` tool includes automatic security restrictions:

- **Environment Files**: Blocks access to `.env`, `.env.local`, and all `.env.*` variations
- **Private Keys**: Blocks SSH keys (`id_rsa`, `id_ed25519`) and private key files
- **Credentials**: Blocks authentication files and credential storage
- **Sensitive Directories**: Restricts access to `.ssh/`, `.aws/`, `.kube/` directories

### File Access Controls

- **Size Limits**: Files are limited to 10MB to prevent memory exhaustion
- **Path Validation**: Prevents directory traversal attacks
- **Error Message Consistency**: Uniform error messages prevent information leakage

## 🚨 Security Risks

### High Risk Areas

1. **File System Access**
   - Agents can read files within the working directory
   - Sensitive files may be accessible if not properly protected
   - File permissions are respected but can be bypassed in some configurations

2. **LLM Provider Integration**
   - API keys are stored in configuration files
   - Conversation content is sent to external providers
   - Sensitive data in conversations may be exposed to third parties

3. **Network Communications**
   - HTTP requests are made to LLM provider APIs
   - Web API endpoints expose agent functionality
   - CORS configuration may allow unauthorized access

4. **Memory and Persistence**
   - Chat history is stored in JSON files
   - Vector database stores conversation embeddings
   - Session data may contain sensitive information

### Medium Risk Areas

1. **Configuration Management**
   - Configuration files contain API keys and settings
   - Default configurations may not be secure for production
   - Environment variables may expose sensitive data

2. **Logging and Monitoring**
   - Debug logs may contain sensitive conversation content
   - OpenTelemetry tracing may expose internal state
   - Error messages could reveal system information

## 🛡️ Security Best Practices

### Before Deployment

1. **Review Configuration**

   ```bash
   # Check configuration file permissions
   ls -la ~/.bots/config.json
   
   # Ensure file is only readable by owner
   chmod 600 ~/.bots/config.json
   ```

2. **Secure API Keys**
   - Use environment variables instead of hardcoded keys
   - Rotate API keys regularly
   - Use read-only API keys when possible
   - Monitor API key usage for anomalies

3. **File System Security**

   ```bash
   # Restrict access to sensitive directories
   chmod 700 ~/.ssh/
   chmod 600 ~/.ssh/id_rsa
   
   # Create dedicated workspace for satibot
   mkdir -p ~/satibot-work
   cd ~/satibot-work
   ```

### During Operation

1. **Network Security**
   - Use VPN or private networks when possible
   - Configure firewall rules to restrict access
   - Use HTTPS for all web API communications
   - Implement rate limiting on web endpoints

2. **Access Control**
   - Run satibot with minimal required permissions
   - Use dedicated user accounts for different deployments
   - Implement authentication for web API endpoints
   - Regularly review access logs

3. **Data Protection**
   - Encrypt sensitive data at rest
   - Use secure deletion for temporary files
   - Regularly clean up old conversation history
   - Implement data retention policies

### Monitoring and Maintenance

1. **Log Monitoring**

   TODO

2. **Regular Security Audits**
   - Review configuration files monthly
   - Check file permissions in workspace
   - Audit API key usage and access patterns
   - Review conversation logs for sensitive data exposure

3. **Update Management**
   - Keep satibot updated to latest version
   - Monitor security advisories for dependencies
   - Test updates in non-production environments first

## Incident Response

### If Security Compromise is Suspected

1. **Immediate Actions**
   - Stop all satibot processes
   - Rotate all API keys
   - Review access logs for unauthorized activity
   - Change any exposed passwords or credentials

2. **Investigation**
   - Check file access logs
   - Review conversation history for data exposure
   - Analyze network logs for unusual connections
   - Document timeline and scope of compromise

3. **Recovery**
   - Update to latest secure version
   - Review and harden configuration
   - Implement additional monitoring
   - Consider security audit by professionals

### Reporting Security Issues

If you discover a security vulnerability:

1. **Do not create public issues**
2. **Email security details to**: [masamonedante@gmail.com](mailto:masamonedante@gmail.com)
3. **Include**: Description, steps to reproduce, and potential impact
4. **Response time**: We aim to respond within 48 hours

## 📋 Security Checklist

### Pre-Deployment Checklist

- [ ] Review and secure configuration files
- [ ] Set appropriate file permissions
- [ ] Use environment variables for API keys
- [ ] Configure network security (firewall, VPN)
- [ ] Set up monitoring and logging
- [ ] Test security restrictions
- [ ] Review data retention policies
- [ ] Document security procedures

### Ongoing Monitoring

- [ ] Monitor API key usage
- [ ] Review access logs regularly
- [ ] Check for unauthorized file access
- [ ] Monitor network traffic
- [ ] Update dependencies regularly
- [ ] Conduct periodic security audits

## 🔗 Additional Resources

- [OWASP AI Security Guidelines](https://owasp.org/www-project-ai-security-and-privacy-guide/)
- [NIST AI Risk Management Framework](https://www.nist.gov/itl/ai-risk-management-framework)
- [Security Best Practices for LLM Applications](https://owasp.org/www-project-top-10-for-large-language-models/)

---

**⚠️ Remember**: Security is an ongoing process. Regular reviews and updates are essential for maintaining a secure deployment.

*Last updated: February 2026*
*Version: 1.0*
