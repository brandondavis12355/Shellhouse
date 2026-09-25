import os
from sqlalchemy import create_engine
from sqlalchemy.orm import sessionmaker, declarative_base

# Swap DATABASE_URL to a postgres:// URL later without touching model code —
# this is the "PostgreSQL as source of truth" decision from the architecture
# doc, just starting on SQLite for a zero-dependency local MVP.
DATABASE_URL = os.environ.get("DATABASE_URL", "sqlite:////data/agent.db")

connect_args = {"check_same_thread": False} if DATABASE_URL.startswith("sqlite") else {}
engine = create_engine(DATABASE_URL, connect_args=connect_args)
SessionLocal = sessionmaker(autocommit=False, autoflush=False, bind=engine)
Base = declarative_base()


def get_db():
    db = SessionLocal()
    try:
        yield db
    finally:
        db.close()
