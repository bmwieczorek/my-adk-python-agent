# Copilot Instructions

These instructions apply to all code changes in this repository.

## SOLID principles for Python

Apply the SOLID design principles adapted for Python:

### S — Single Responsibility Principle (SRP)

- Each module, class, or function should have one reason to change.
- Agents handle orchestration OR validation OR presentation — never all three.
- If a module grows beyond one concern, split it.

### O — Open/Closed Principle (OCP)

- Design modules to be extended without modifying existing code.
- Prefer configuration-driven factories (e.g. `generate_flights(**config)`) over
  editing a shared function body for each new variant.
- Use protocol classes or ABCs when a stable interface needs multiple
  implementations.

### L — Liskov Substitution Principle (LSP)

- Subclasses and protocol implementations must be usable wherever their base
  type is expected, without breaking behaviour.
- In Python this applies to ABCs, Protocol classes, and duck-typed interfaces
  alike — honour the expected input/output contract.

### I — Interface Segregation Principle (ISP)

- Keep interfaces (ABCs, Protocols, function signatures) small and focused.
- Don't force callers to depend on methods or parameters they don't use.
- Prefer multiple small Protocols over one large one.

### D — Dependency Inversion Principle (DIP)

- High-level modules should not import low-level implementation details directly.
- Depend on abstractions (Protocols, config dicts, factory functions) rather than
  concrete implementations when the concrete type may change.
- Example: airline agents import a shared `generate_flights` utility rather than
  each embedding their own flight-generation logic.

## DRY principle (Don't Repeat Yourself)

- Extract shared logic into common/utility modules rather than duplicating code
  across files. If two or more modules contain the same algorithm or business
  logic, consolidate into a single source of truth and have each caller invoke
  it with its own parameters.
- Wrapper functions that add identity (e.g. unique names, docstrings for LLM
  tool discovery) are acceptable — they are not duplication as long as the core
  logic they delegate to is shared.
- When the DRY refactor would hurt clarity, testability, or violate a framework
  constraint (e.g. ADK tool naming), keep the duplication and leave a comment
  explaining why.

## PEP 8 compliance

- All Python code must follow [PEP 8](https://peps.python.org/pep-0008/).
- Maximum line length: 88 characters (Black default) or 79 (strict PEP 8) —
  stay consistent within the project.
- Use 4-space indentation, no tabs.
- Imports must be grouped in standard order: stdlib → third-party → local, with
  a blank line between each group. Use absolute imports.
- Naming conventions:
  - `snake_case` for functions, methods, variables, and module names.
  - `PascalCase` for classes.
  - `UPPER_SNAKE_CASE` for module-level constants.
  - `_leading_underscore` for private/internal names.
- Use type hints on all function signatures (parameters and return types).
- Docstrings are required on all public functions, classes, and modules
  (Google style).
- Only add inline comments when the code would be unclear without them.

## ADK-specific conventions

- Each agent lives in its own `<agent_name>/agent.py` module with an
  `__init__.py` alongside it.
- Tool functions exposed to LLM agents must have descriptive `__name__` and
  docstrings — the LLM uses both for tool selection.
- Shared utilities go in a `common.py` next to the agents that use them,
  not inside any single agent's directory.
- The use case requirements defined in `my_multi_agent/requirements_spec.py`
  MUST always be met. Any code change to the multi-agent system must be
  validated against all use cases in that file. If a change would break a
  use case, either fix the change or flag the conflict before proceeding.
- Use `ParallelAgent` for concurrent work and `SequentialAgent` only when
  deterministic ordering is required and LLM-based chaining is unreliable.

## Git commit conventions

- Do NOT include `Co-authored-by` trailers for Copilot, Gemini, or any other
  AI assistant in commit messages.
- Never commit files containing real GCP project IDs, cluster names, service
  account emails, registry URLs, or other environment-specific values. Always
  use placeholders (e.g. `${GOOGLE_CLOUD_PROJECT}`, `${GKE_CLUSTER_NAME}`) or
  shell variables that are resolved at runtime.
