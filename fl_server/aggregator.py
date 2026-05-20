"""
Smart Vision Assist - Federated Learning Aggregation Server

Firestore-only FL demo pipeline:
  1. Read client update documents from fl_model_updates/.
  2. Run FedAvg over each update's 80-dim class-activation vector.
  3. Write the current global model to fl_global_model/current.
  4. Log each aggregation round to fl_rounds/.

No Firebase Storage is used. This keeps the graduation demo on Firestore only.

Usage:
    cd fl_server
    python aggregator.py
    python aggregator.py --watch 300
    python aggregator.py --key /path/to/key.json --watch 60
"""

import argparse
import time
from datetime import datetime, timezone
from pathlib import Path

import firebase_admin
import numpy as np
from firebase_admin import credentials, firestore

# Resolved from: smart_vision_app/fl_server/../serviceAccountKey.json
_DEFAULT_KEY = Path(__file__).parent.parent / "serviceAccountKey.json"

_UPDATES_COLLECTION = "fl_model_updates"
_GLOBAL_MODEL_COLLECTION = "fl_global_model"
_GLOBAL_MODEL_DOC = "current"
_ROUNDS_COLLECTION = "fl_rounds"

# Number of represented samples required before aggregation runs.
_MIN_SAMPLES = 5

# Expected embedding dimension (80 COCO classes).
_EMBEDDING_DIM = 80


def init_firebase(key_path: str) -> None:
    """Initialises the Firebase Admin SDK (idempotent)."""
    if not firebase_admin._apps:
        cred = credentials.Certificate(key_path)
        firebase_admin.initialize_app(cred)


def _to_float_vector(raw: object) -> np.ndarray:
    if not isinstance(raw, list):
        raise ValueError("local_weights must be a list")
    vec = np.array(raw, dtype=np.float32)
    if vec.shape != (_EMBEDDING_DIM,):
        raise ValueError(f"Expected ({_EMBEDDING_DIM},), got {vec.shape}")
    return vec


def load_all_client_updates() -> dict[str, list[tuple[np.ndarray, int, str]]]:
    """
    Reads FL client updates from Firestore and returns:
        { uid: [(local_update_array, sample_count, document_id), ...], ... }

    Expected document shape under fl_model_updates/{docId}:
      uid: string
      sample_count: number
      local_weights: list[80]
      status: "pending" | "aggregated" | ...
    """
    db = firestore.client()
    query = (
        db.collection(_UPDATES_COLLECTION)
        .where("status", "==", "pending")
        .stream()
    )

    user_updates: dict[str, list[tuple[np.ndarray, int, str]]] = {}
    skipped = 0

    for doc in query:
        data = doc.to_dict() or {}
        uid = data.get("uid")
        if not uid:
            print(f"  [skip] {_UPDATES_COLLECTION}/{doc.id}: missing uid")
            skipped += 1
            continue

        try:
            vec = _to_float_vector(data.get("local_weights"))
            sample_count = int(data.get("sample_count", 1))
            if sample_count <= 0:
                raise ValueError("sample_count must be positive")
            user_updates.setdefault(uid, []).append((vec, sample_count, doc.id))
        except Exception as exc:
            print(f"  [skip] {_UPDATES_COLLECTION}/{doc.id}: {exc}")
            skipped += 1

    if skipped:
        print(f"  {skipped} malformed Firestore update document(s) skipped.")

    return user_updates


def federated_average(
    user_updates: dict[str, list[tuple[np.ndarray, int, str]]],
) -> tuple[np.ndarray, dict]:
    """
    Weighted Federated Averaging:
        global_weights = sum(n_i * local_mean_i) / sum(n_i)

    where n_i is the number of samples contributed by user i.
    """
    weighted_sum = np.zeros(_EMBEDDING_DIM, dtype=np.float64)
    total_samples = 0
    per_user_stats: dict[str, dict] = {}
    aggregated_doc_ids: list[str] = []

    for uid, updates in user_updates.items():
        n = sum(sample_count for _, sample_count, _ in updates)
        if n <= 0:
            continue

        local_sum = np.zeros(_EMBEDDING_DIM, dtype=np.float64)
        for local_weights, sample_count, doc_id in updates:
            local_sum += sample_count * local_weights
            aggregated_doc_ids.append(doc_id)

        local_mean = local_sum / n
        weighted_sum += n * local_mean
        total_samples += n
        per_user_stats[uid] = {
            "samples": n,
            "updates": len(updates),
            "local_mean_norm": float(np.linalg.norm(local_mean)),
        }

    if total_samples == 0:
        raise ValueError("No valid FL updates were available for aggregation.")

    global_weights = (weighted_sum / total_samples).astype(np.float32)
    stats = {
        "total_users": len(per_user_stats),
        "total_samples": total_samples,
        "per_user": per_user_stats,
        "aggregated_update_doc_ids": aggregated_doc_ids,
        "global_weight_norm": float(np.linalg.norm(global_weights)),
        "global_weight_max": float(global_weights.max()),
        "global_weight_min": float(global_weights.min()),
    }
    return global_weights, stats


def save_global_model(weights: np.ndarray, round_id: str) -> None:
    """Writes the aggregated global weights to Firestore."""
    payload = {
        "round_id": round_id,
        "updated_at": datetime.now(timezone.utc).isoformat(),
        "updated_at_server": firestore.SERVER_TIMESTAMP,
        "dimensions": _EMBEDDING_DIM,
        "description": (
            "Per-class max-pooled class-activation features aggregated via "
            "FedAvg. Index i = max detection score for COCO class i."
        ),
        "global_weights": weights.tolist(),
    }

    firestore.client().collection(_GLOBAL_MODEL_COLLECTION).document(
        _GLOBAL_MODEL_DOC
    ).set(payload)
    print(
        "  Saved global model -> "
        f"Firestore/{_GLOBAL_MODEL_COLLECTION}/{_GLOBAL_MODEL_DOC}"
    )


def log_round_to_firestore(round_id: str, stats: dict) -> None:
    """Records aggregation metadata under fl_rounds/{round_id} in Firestore."""
    firestore.client().collection(_ROUNDS_COLLECTION).document(round_id).set(
        {
            "round_id": round_id,
            "completed_at": firestore.SERVER_TIMESTAMP,
            **stats,
        }
    )
    print(f"  Logged round -> Firestore/{_ROUNDS_COLLECTION}/{round_id}")


def mark_updates_aggregated(doc_ids: list[str], round_id: str) -> None:
    """Marks consumed update documents so later runs do not double-count them."""
    if not doc_ids:
        return

    db = firestore.client()
    batch = db.batch()
    for doc_id in doc_ids:
        ref = db.collection(_UPDATES_COLLECTION).document(doc_id)
        batch.update(
            ref,
            {
                "status": "aggregated",
                "aggregated_round_id": round_id,
                "aggregated_at": firestore.SERVER_TIMESTAMP,
            },
        )
    batch.commit()
    print(f"  Marked {len(doc_ids)} update document(s) as aggregated.")


def run_aggregation(min_samples: int = _MIN_SAMPLES) -> bool:
    """
    Executes one full aggregation round.
    Returns True if aggregation ran, False if skipped (not enough data).
    """
    ts = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    print(f"\n[{ts}] Starting aggregation round...")

    user_updates = load_all_client_updates()
    total = sum(
        sample_count for updates in user_updates.values()
        for _, sample_count, _ in updates
    )
    print(f"  Found {total} represented sample(s) from {len(user_updates)} user(s).")

    if total < min_samples:
        print(f"  Skipping - need at least {min_samples} samples to aggregate.")
        return False

    global_weights, stats = federated_average(user_updates)

    round_id = f"round_{datetime.now(timezone.utc).strftime('%Y%m%d_%H%M%S')}"
    save_global_model(global_weights, round_id)
    log_round_to_firestore(round_id, stats)
    mark_updates_aggregated(stats["aggregated_update_doc_ids"], round_id)

    print(
        f"  Done. Round: {round_id} | "
        f"Users: {stats['total_users']} | "
        f"Samples: {stats['total_samples']} | "
        f"Global norm: {stats['global_weight_norm']:.4f}"
    )
    return True


def main() -> None:
    parser = argparse.ArgumentParser(
        description="FAVS Federated Learning Aggregation Server",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )
    parser.add_argument(
        "--key",
        default=str(_DEFAULT_KEY),
        help="Path to Firebase service account JSON key file.",
    )
    parser.add_argument(
        "--watch",
        type=int,
        default=0,
        metavar="SECONDS",
        help="Re-run aggregation every N seconds. 0 = one-shot.",
    )
    parser.add_argument(
        "--min-samples",
        type=int,
        default=_MIN_SAMPLES,
        dest="min_samples",
        help="Minimum total samples before aggregation runs.",
    )
    args = parser.parse_args()

    key_path = args.key
    if not Path(key_path).exists():
        raise FileNotFoundError(
            f"\nService account key not found at: {key_path}\n"
            "Either place serviceAccountKey.json in the project root,\n"
            "or pass --key <path/to/serviceAccountKey.json>."
        )

    init_firebase(key_path)
    print("Firebase connected. Firestore-only FL mode.")
    print(f"Minimum samples to aggregate: {args.min_samples}")

    if args.watch > 0:
        print(f"Watch mode active - aggregating every {args.watch}s. Ctrl+C to stop.\n")
        try:
            while True:
                run_aggregation(min_samples=args.min_samples)
                print(f"  Sleeping {args.watch}s...")
                time.sleep(args.watch)
        except KeyboardInterrupt:
            print("\nAggregation server stopped.")
    else:
        run_aggregation(min_samples=args.min_samples)


if __name__ == "__main__":
    main()
