# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

<!-- changelog -->

## [Unreleased]

## [2025.11.14-preview] - 2025-11-14

### Added

- `LLMDB.Model.format_spec/1` function for converting model struct to provider:model string format
- Zai Coder provider and GLM models support
- Enhanced cost schema with granular multimodal and reasoning pricing fields:
  - `reasoning`: Cost per 1M reasoning/thinking tokens for models like o1, Grok-4
  - `input_audio`/`output_audio`: Separate audio input/output costs (e.g., Gemini 2.5 Flash, Qwen-Omni)
  - `input_video`/`output_video`: Video input/output cost support for future models
- ModelsDev source transformer now captures all cost fields from models.dev data
- OpenRouter source transformer maps `internal_reasoning` field to `reasoning` cost

### Changed

- Updated Zoi dependency to version 0.10.6
- Refactored loader to use dynamic snapshot retrieval
- Disabled schema validation in snapshot.json and TOML source files

### Fixed

- Cleaned up code quality issues
