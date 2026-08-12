# Kendall-DOM
# PMO Digital Operating Model

 

## Overview

 

The PMO Digital Operating Model is a structured, relational representation of the PMO New Project Intake process. The purpose of this project is to document and model the workflow, roles, artifacts, decisions, gates, systems, governance elements, and relationships that support project initiation activities.

 

This project serves as the foundation for a larger Business Operating System (BOS) initiative, providing a scalable and reusable framework that can be extended to additional PMO phases, business processes, and departments in the future.

 

---

 

## Objectives

 

- Create a navigable digital representation of the PMO intake process.

- Define business entities and their relationships.

- Maintain traceability between processes, artifacts, roles, systems, and governance elements.

- Establish a scalable relational data model.

- Support future enterprise database implementations.

- Enable future reporting, analytics, and operational visibility.

 

---

 

## Phase 1 Scope

 

Current scope focuses on the PMO New Project Intake process and includes the following entity types:

 

- Process Steps

- Gates

- Decisions

- Workflow Paths

- Roles

- Artifacts

- Systems / Tools

- Source Documents

- Metric Hooks

- Governance

- Questions / Gaps

- Relationships

 

---

 

## Technology Stack

 

### Current

 

- GitHub

- PostgreSQL

- Railway

 

### Planned

 

- Database Viewer/UI

- Analytics & Reporting Layer

- Enterprise Hosting Environment

- API Integrations

 

---

 

## Repository Structure

 

```text

PMO-Operating-Model/

 

├── docs/

│ ├── ERD

│ ├── Data Dictionary

│ ├── Schema

│ ├── Relationship Matrix

│ └── Supporting Documentation

│

├── database/

│ ├── table creation scripts

│ ├── seed data

│ └── migrations

│

├── data/

│ ├── sample data

│ └── entity exports

│

├── scripts/

│ └── utility scripts

│

└── README.md

```

 

---

 

## Proof of Concept

 

The initial proof of concept will focus on four core entities:

 

1. Roles

2. Process Steps

3. Artifacts

4. Gates

 

The goal of this phase is to validate:

 

- Relational database design

- Entity relationships

- PostgreSQL implementation

- GitHub collaboration workflow

- Future scalability of the data model

 

---

 

## Design Principles

 

- Model current-state processes only.

- Preserve traceability to source materials.

- Use role-based ownership rather than individual ownership.

- Design for scalability and future database expansion.

- Separate entities by responsibility and purpose.

- Maintain relationship integrity across all entities.

 

---

 

## Development Workflow

 

1. Pull the latest changes from GitHub.

2. Make changes locally.

3. Test all database updates.

4. Commit changes with a descriptive message.

5. Push updates to the repository.

 

Example:

 

```bash

git add .

git commit -m "Added roles table and sample seed data"

git push

```

 

---

 

## Current Status

 

Active Development

 

Current focus:

 

- Establish PostgreSQL database structure.

- Build initial proof-of-concept database.

- Validate relationships between Roles, Process Steps, Artifacts, and Gates.

- Prepare the foundation for the full PMO Operating Model architecture.
