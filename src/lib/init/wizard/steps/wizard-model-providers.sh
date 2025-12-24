#!/usr/bin/env bash
# wizard-model-providers.sh - Wizard step for AI model provider API keys
# Triggered when AI services are selected in custom services

# Check if any AI services are selected
has_ai_services_selected() {
  local config_array_name="$1"
  local -n config_ref=$config_array_name
  
  # Check for AI_SERVICES_SELECTED flag (set when Memobase or GraphRAG selected)
  for item in "${config_ref[@]}"; do
    if [[ "$item" == *"AI_SERVICES_SELECTED=true"* ]]; then
      return 0
    fi
  done
  
  # Also check for specific AI service template types in custom services
  for item in "${config_ref[@]}"; do
    case "$item" in
      *:memobase:*|*:graphrag:*|*:llamaindex:*)
        return 0
        ;;
    esac
  done
  
  return 1
}

# Configure AI model provider API keys
wizard_model_providers() {
  local config_array_name="$1"
  
  clear
  show_wizard_step 9 12 "AI Model Providers"
  
  echo "🤖 AI Model Provider Configuration"
  echo ""
  echo "Your selected AI services require LLM API keys."
  echo "These keys will be stored securely in .env.secrets"
  echo ""
  echo "Configure the providers you want to use:"
  echo ""
  
  # Track if any key was provided
  local has_any_key=false
  
  # OpenAI (most common)
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "🟢 OpenAI"
  echo "  Required for: Memobase, many AI services"
  echo "  Get key: https://platform.openai.com/api-keys"
  if confirm_action "Configure OpenAI API Key?"; then
    local openai_key
    prompt_password "OpenAI API Key" openai_key
    if [[ -n "$openai_key" ]]; then
      add_wizard_secret "$config_array_name" "OPENAI_API_KEY" "$openai_key"
      has_any_key=true
      echo "  ✓ OpenAI key configured"
    fi
  fi
  echo ""
  
  # OpenRouter (model flexibility)
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "🔀 OpenRouter"
  echo "  Access 100+ models via single API"
  echo "  Get key: https://openrouter.ai/keys"
  if confirm_action "Configure OpenRouter API Key?"; then
    local openrouter_key
    prompt_password "OpenRouter API Key" openrouter_key
    if [[ -n "$openrouter_key" ]]; then
      add_wizard_secret "$config_array_name" "OPENROUTER_API_KEY" "$openrouter_key"
      has_any_key=true
      echo "  ✓ OpenRouter key configured"
      
      echo ""
      echo "  Select default models for OpenRouter:"
      
      local txt_model emb_model img_model base_url
      prompt_input "Text Model" "x-ai/grok-4.1-fast" txt_model
      prompt_input "Embedding Model" "openai/text-embedding-3-large" emb_model
      prompt_input "Image Model" "google/gemini-2.5-flash-image" img_model
      prompt_input "Base URL" "https://openrouter.ai/api/v1" base_url
      
      add_wizard_config "$config_array_name" "OPENROUTER_MODEL_TXT" "$txt_model"
      add_wizard_config "$config_array_name" "OPENROUTER_MODEL_EMB" "$emb_model"
      add_wizard_config "$config_array_name" "OPENROUTER_MODEL_IMG" "$img_model"
      add_wizard_config "$config_array_name" "OPENROUTER_BASE_URL" "$base_url"
    fi
  fi
  echo ""
  
  # Anthropic
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "🟣 Anthropic (Claude)"
  echo "  Get key: https://console.anthropic.com/"
  if confirm_action "Configure Anthropic API Key? (optional)"; then
    local anthropic_key
    prompt_password "Anthropic API Key" anthropic_key
    if [[ -n "$anthropic_key" ]]; then
      add_wizard_secret "$config_array_name" "ANTHROPIC_API_KEY" "$anthropic_key"
      has_any_key=true
      echo "  ✓ Anthropic key configured"
    fi
  fi
  echo ""
  
  # Cohere
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "🟠 Cohere"
  echo "  Get key: https://dashboard.cohere.com/api-keys"
  if confirm_action "Configure Cohere API Key? (optional)"; then
    local cohere_key
    prompt_password "Cohere API Key" cohere_key
    if [[ -n "$cohere_key" ]]; then
      add_wizard_secret "$config_array_name" "COHERE_API_KEY" "$cohere_key"
      has_any_key=true
      echo "  ✓ Cohere key configured"
    fi
  fi
  echo ""
  
  # HuggingFace
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "🟡 HuggingFace"
  echo "  Get token: https://huggingface.co/settings/tokens"
  if confirm_action "Configure HuggingFace Token? (optional)"; then
    local hf_token
    prompt_password "HuggingFace Token" hf_token
    if [[ -n "$hf_token" ]]; then
      add_wizard_secret "$config_array_name" "HUGGINGFACE_API_KEY" "$hf_token"
      has_any_key=true
      echo "  ✓ HuggingFace token configured"
    fi
  fi
  echo ""
  
  # Summary
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  if [[ "$has_any_key" == "true" ]]; then
    echo "✅ API keys configured successfully"
    echo "   Keys will be stored in .env.secrets (not committed to git)"
  else
    echo "⚠️  No API keys configured"
    echo "   You can add them later by editing .env.secrets"
  fi
  echo ""
  
  press_any_key
  return 0
}

# Export functions
export -f has_ai_services_selected
export -f wizard_model_providers
