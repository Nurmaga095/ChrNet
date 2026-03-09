# Project Memory / AGENTS.md

This file contains persistent instructions for AI agents working with this repository.

The AI must read this file before modifying the project.

---

# Project Overview

This project is a Flutter VPN client application.

Main goals:
- Provide a simple VPN client interface
- Allow users to import VPN configurations
- Connect and disconnect from VPN servers
- Manage user subscriptions

---

# Tech Stack

- Flutter (latest stable)
- Dart
- Android + iOS support
- VPN protocols handled through native platform integrations

---

# Architecture

The project follows a modular structure.

Main layers:

UI Layer
- Screens
- Widgets
- User interactions

Service Layer
- VPN management
- Configuration import
- Connection control

Data Layer
- Storage of configurations
- Local user settings

---

# Folder Structure

Example structure:

lib/

core/
- constants
- helpers
- utilities

services/
- vpn_service
- config_service

models/
- vpn_config
- user_data

ui/
- screens
- widgets

platform/
- native integrations

---

# Coding Rules

AI must follow these rules when modifying code:

1. Do not break existing architecture.
2. Avoid large refactors unless explicitly requested.
3. Keep functions small and readable.
4. Use meaningful variable names.
5. Follow Flutter best practices.
6. Prefer reusable widgets.

---

# Development Rules

Before making changes:

1. Read AGENTS.md
2. Understand the file structure
3. Avoid unnecessary changes

After making changes:

1. Ensure code compiles
2. Avoid introducing warnings
3. Keep formatting consistent

---

# Flutter Rules

- Use StatelessWidget whenever possible
- Avoid deep widget nesting
- Separate UI and logic
- Keep business logic out of widgets

---

# VPN Logic

Important:

VPN logic must remain stable.

Connection flow:

1. Import config
2. Store config
3. Initialize VPN engine
4. Connect
5. Monitor connection state
6. Disconnect safely

Do not modify connection flow without clear reason.

---

# AI Editing Rules

When editing the project:

- Prefer minimal changes
- Do not rewrite entire files unless necessary
- Preserve comments and documentation
- Follow existing coding style

---

# TODO Tracking

If the AI finds improvements:

Add them to a TODO list instead of modifying large parts of the project.

---

# Important

This file acts as persistent memory for AI agents.

Update this file if:

- architecture changes
- folder structure changes
- major features are added
