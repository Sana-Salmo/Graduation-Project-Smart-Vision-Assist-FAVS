"""
Smart Vision Assist — Federated Learning Simulation (Flower Framework)

Simulates federated learning across 8 virtual clients using 80-dim
class-activation embeddings collected by the on-device FL pipeline.

Each client represents a user with a different visual environment
(e.g., an indoor office worker vs. an outdoor pedestrian). The simulation
shows how FedAvg converges toward a global class-activation prior that
benefits all clients without centralising raw data.

Mathematical model
------------------
Global model     : w ∈ R^80  (class-activation prior vector)
Local objective  : L(w; Dᵢ) = ½ ‖w − μᵢ‖²   (MSE vs. local mean)
Local update     : w ← w − η(w − μᵢ)          (gradient descent)
FedAvg           : w_global = Σ (nᵢ/n) · wᵢ   (weighted aggregation)

Reference: McMahan et al. "Communication-Efficient Learning of Deep Networks
           from Decentralized Data." AISTATS 2017.

Outputs (written to fl_server/plots/)
--------------------------------------
  convergence.png    — loss, weight drift, accuracy over 10 FL rounds
  distributions.png  — per-client class-activation heatmap + bar chart

Usage
-----
    cd fl_server
    pip install -r requirements.txt

    python fl_simulation.py                          # 8 clients, 10 rounds
    python fl_simulation.py --rounds 15 --clients 10 --samples 50
    python fl_simulation.py --real-data              # load real on-device samples
"""

import argparse
import json
from pathlib import Path
from typing import Dict, List, Optional, Tuple

import flwr as fl
import matplotlib.pyplot as plt
import numpy as np

# ── Global hyper-parameters ───────────────────────────────────────────────────

EMBEDDING_DIM = 80       # number of COCO classes (YOLOv8n output)
NUM_ROUNDS = 10          # FL communication rounds
NUM_CLIENTS = 8          # virtual clients in the simulation
SAMPLES_PER_CLIENT = 30  # synthetic samples per client
LOCAL_EPOCHS = 3         # gradient-descent steps per round per client
LEARNING_RATE = 0.15     # step size η for local gradient descent
RANDOM_SEED = 42         # reproducibility

# ── COCO class names (80 classes, order matches YOLOv8 label file) ─────────────

COCO_CLASSES: List[str] = [
    'person', 'bicycle', 'car', 'motorcycle', 'airplane', 'bus', 'train',
    'truck', 'boat', 'traffic light', 'fire hydrant', 'stop sign',
    'parking meter', 'bench', 'bird', 'cat', 'dog', 'horse', 'sheep', 'cow',
    'elephant', 'bear', 'zebra', 'giraffe', 'backpack', 'umbrella', 'handbag',
    'tie', 'suitcase', 'frisbee', 'skis', 'snowboard', 'sports ball', 'kite',
    'baseball bat', 'baseball glove', 'skateboard', 'surfboard',
    'tennis racket', 'bottle', 'wine glass', 'cup', 'fork', 'knife', 'spoon',
    'bowl', 'banana', 'apple', 'sandwich', 'orange', 'broccoli', 'carrot',
    'hot dog', 'pizza', 'donut', 'cake', 'chair', 'couch', 'potted plant',
    'bed', 'dining table', 'toilet', 'tv', 'laptop', 'mouse', 'remote',
    'keyboard', 'cell phone', 'microwave', 'oven', 'toaster', 'sink',
    'refrigerator', 'book', 'clock', 'vase', 'scissors', 'teddy bear',
    'hair drier', 'toothbrush',
]

# ── Client profiles ───────────────────────────────────────────────────────────
#
# Each tuple is (profile_name, [specialty_class_indices]).
# Specialty classes are ones that appear frequently in uncertain-confidence
# detections for that user's environment.  They are sampled from the FL
# collection window [0.28, 0.43] to mimic real on-device data.

CLIENT_PROFILES: List[Tuple[str, List[int]]] = [
    # (name,                    specialty class indices)
    ('Indoor Office',           [63, 56, 64, 66, 67, 39, 41]),
    #                            laptop chair mouse keybd phone bottle cup
    ('Outdoor Pedestrian',      [0,  1,  2,  9,  11, 13]),
    #                            person bicy car  tlight stop  bench
    ('Home User',               [57, 62, 59, 60, 58, 74]),
    #                            couch  tv   bed  dtbl  plant clock
    ('Kitchen User',            [39, 41, 45, 60, 56]),
    #                            bottle cup  bowl dtbl  chair
    ('Public Space',            [0,  13, 10, 5,  7]),
    #                            person bench hydrant bus truck
    ('Student',                 [73, 63, 56, 24, 67]),
    #                            book laptop chair backpack phone
    ('Driver / Commuter',       [2,  9,  11, 7,  5,  6]),
    #                            car  tlight stop  truck bus  train
    ('Pet Owner',               [15, 16, 0,  57, 59]),
    #                            cat  dog  person couch bed
]

# ── Data generation ───────────────────────────────────────────────────────────

def generate_client_data(
    profile: Tuple[str, List[int]],
    n_samples: int,
    rng: np.random.Generator,
) -> np.ndarray:
    """
    Generates synthetic 80-dim class-activation embeddings for one client.

    Sampling model
    ~~~~~~~~~~~~~~
    For each sample x ∈ R^80 and class index c:

        x[c] ~ Uniform(0.28, 0.43) + N(0, 0.03)   if c ∈ specialty_classes
        x[c] ~ Uniform(0.05, 0.20) + N(0, 0.02)   otherwise

        x = clip(x, 0, 1)

    The specialty window [0.28, 0.43] sits inside the FL collection window
    [0.25, 0.44].  Non-specialty values are low — the model confidently
    ignores those classes in that user's environment.

    Args:
        profile   : (name, specialty_indices) tuple from CLIENT_PROFILES
        n_samples : number of synthetic samples to generate
        rng       : seeded numpy Generator for reproducibility

    Returns:
        Float32 array of shape (n_samples, 80)
    """
    _, specialty_idx = profile

    # Background: low activation for all classes.
    data = rng.uniform(0.05, 0.20, size=(n_samples, EMBEDDING_DIM)).astype(np.float32)
    data += rng.normal(0.0, 0.02, size=data.shape).astype(np.float32)

    # Elevated activation for specialty classes (uncertain region).
    for idx in specialty_idx:
        data[:, idx] = (
            rng.uniform(0.28, 0.43, size=n_samples)
            + rng.normal(0.0, 0.03, size=n_samples)
        ).astype(np.float32)

    return np.clip(data, 0.0, 1.0)


def load_or_generate_data(
    n_samples_per_client: int,
    samples_dir: Optional[Path],
) -> List[Tuple[str, np.ndarray]]:
    """
    If --real-data is set and samples_dir contains JSON files, loads them.
    Otherwise generates synthetic data using CLIENT_PROFILES.

    Returns a list of (client_name, data_array) tuples.
    """
    rng = np.random.default_rng(RANDOM_SEED)

    if samples_dir and samples_dir.exists():
        json_files = sorted(samples_dir.glob('*.json'))
        if json_files:
            print(f"Loading {len(json_files)} real sample(s) from {samples_dir}")
            return _load_real_data(json_files, rng)

    print("Generating synthetic client data (use --real-data to load real samples).")
    datasets: List[Tuple[str, np.ndarray]] = []
    for profile in CLIENT_PROFILES:
        name, _ = profile
        data = generate_client_data(profile, n_samples_per_client, rng)
        datasets.append((name, data))
        print(f"  {name:24s}  n={data.shape[0]}  "
              f"μ={data.mean():.3f}  σ={data.std():.3f}")
    return datasets


def _load_real_data(
    json_files: List[Path],
    rng: np.random.Generator,
) -> List[Tuple[str, np.ndarray]]:
    """Parses real on-device JSON samples, groups by device UID."""
    by_uid: Dict[str, List[np.ndarray]] = {}
    for f in json_files:
        try:
            data = json.loads(f.read_text())
            vec = np.array(data['feature_vector'], dtype=np.float32)
            if vec.shape == (EMBEDDING_DIM,):
                uid = f.stem.split('_')[0] if '_' in f.stem else 'device_0'
                by_uid.setdefault(uid, []).append(vec)
        except Exception:
            continue

    result: List[Tuple[str, np.ndarray]] = []
    for i, (uid, vecs) in enumerate(by_uid.items()):
        profile_name = CLIENT_PROFILES[i % len(CLIENT_PROFILES)][0]
        result.append((f"{profile_name} (real)", np.stack(vecs)))
    return result


# ── Flower client ─────────────────────────────────────────────────────────────

class FlowerClient(fl.client.NumPyClient):
    """
    Flower NumPyClient that learns a class-activation prior from local data.

    The 'model' is a single weight vector w ∈ R^80.  Each element wᵢ
    represents the expected uncertain-detection strength for COCO class i
    in this client's environment.

    Local training objective
    ~~~~~~~~~~~~~~~~~~~~~~~~
        L(w; Dᵢ) = ½ ‖w − μᵢ‖²         (Mean Squared Error)

    where μᵢ = (1/nᵢ) Σ_{x ∈ Dᵢ} x    (per-client class-activation mean)

    The MSE gradient is:  ∂L/∂w = w − μᵢ

    Gradient descent update:
        w ← w − η(w − μᵢ)
          = (1 − η)w + η·μᵢ              (exponential moving average)

    With η < 1, this converges to μᵢ over multiple epochs but retains
    some influence from the global model — which is the mechanism that
    prevents catastrophic client drift in FedAvg.
    """

    def __init__(self, name: str, local_data: np.ndarray) -> None:
        self.name = name
        self.local_data = local_data
        # Pre-compute μᵢ once (does not change during simulation).
        self.local_mean: np.ndarray = local_data.mean(axis=0).astype(np.float64)

    def get_parameters(self, config: dict) -> List[np.ndarray]:
        """Returns the client's local mean as its initial parameter estimate."""
        return [self.local_mean.astype(np.float32)]

    def fit(
        self,
        parameters: List[np.ndarray],
        config: dict,
    ) -> Tuple[List[np.ndarray], int, dict]:
        """
        Runs E local gradient-descent steps on the MSE objective.

        FedAvg calls this once per round, broadcasting the current global
        weights w_t.  The returned (w_updated, n_samples) pair is used by
        the server to compute the weighted average:

            w_global = Σ nᵢ·wᵢ / Σ nᵢ

        The nᵢ returned here acts as the FedAvg sample weight for this client.

        Args:
            parameters : [w_global] — server-side global weights
            config     : {"local_epochs": int, "learning_rate": float}

        Returns:
            ([w_updated], n_samples, {"train_loss": float})
        """
        w = parameters[0].astype(np.float64).copy()
        lr: float = config.get('learning_rate', LEARNING_RATE)
        epochs: int = config.get('local_epochs', LOCAL_EPOCHS)

        for _ in range(epochs):
            # Gradient of ½‖w − μᵢ‖² with respect to w.
            gradient = w - self.local_mean
            w -= lr * gradient

        train_loss = float(0.5 * np.mean((w - self.local_mean) ** 2))
        return [w.astype(np.float32)], len(self.local_data), {'train_loss': train_loss}

    def evaluate(
        self,
        parameters: List[np.ndarray],
        config: dict,
    ) -> Tuple[float, int, dict]:
        """
        Evaluates the global model against this client's distribution.

        Loss:     MSE between global weights and local class-activation mean.
        Accuracy: fraction of COCO classes where global and local models agree
                  on whether the class is 'uncertain' (score > 0.30 threshold).

        A high agreement accuracy means the global prior correctly captures
        which classes are uncertain in this client's environment.

        Args:
            parameters: [w_global] — current global model weights

        Returns:
            (loss, n_samples, {"accuracy": float})
        """
        w = parameters[0].astype(np.float64)
        loss = float(0.5 * np.mean((w - self.local_mean) ** 2))

        # Proxy accuracy: class-level agreement on uncertain detections.
        # Threshold 0.30 separates uncertain classes from confident ones.
        uncertain_threshold = 0.30
        agree = (w > uncertain_threshold) == (self.local_mean > uncertain_threshold)
        accuracy = float(agree.mean())

        return loss, len(self.local_data), {'accuracy': accuracy}


# ── FedAvg implementation ─────────────────────────────────────────────────────

def federated_average(
    client_updates: List[Tuple[np.ndarray, int]],
) -> np.ndarray:
    """
    Federated Averaging — McMahan et al. (2017), Algorithm 1.

        w_global = Σᵢ (nᵢ / n) · wᵢ

    where n = Σᵢ nᵢ is the total number of samples across all K clients.

    Clients with more local data exert proportionally greater influence on
    the global model.  This is the core FedAvg weighting rule.

    Args:
        client_updates: list of (w_i, n_i) — updated weights and sample count

    Returns:
        Aggregated global weights of shape (EMBEDDING_DIM,)
    """
    total_n = sum(n for _, n in client_updates)
    weighted_sum = np.zeros(EMBEDDING_DIM, dtype=np.float64)
    for w, n in client_updates:
        weighted_sum += n * w.astype(np.float64)
    return (weighted_sum / total_n).astype(np.float32)


# ── Simulation loop ───────────────────────────────────────────────────────────

def run_simulation(clients: List[FlowerClient], num_rounds: int) -> dict:
    """
    Executes the federated learning simulation over `num_rounds` rounds.

    Each round t follows the FedAvg protocol:
      1. Server broadcasts w_t to all K clients.
      2. Each client runs fit(w_t) → locally-updated weights wᵢ(t).
      3. Server aggregates:  w_{t+1} = Σ (nᵢ/n) · wᵢ(t).
      4. Server evaluates w_{t+1} on all clients and records metrics.

    Returns a history dict containing per-round scalars for plotting.
    """
    # Initialise global model to the zero vector (uninformed prior).
    w_global = np.zeros(EMBEDDING_DIM, dtype=np.float32)
    fit_config = {'local_epochs': LOCAL_EPOCHS, 'learning_rate': LEARNING_RATE}

    history: dict = {
        'rounds':              list(range(1, num_rounds + 1)),
        'avg_loss':            [],
        'avg_accuracy':        [],
        'weight_drift':        [],
        'round_weights':       [],
        'per_client_loss':     [],
        'per_client_accuracy': [],
    }

    sep = '─' * 62
    print(f'\n{sep}')
    print(f'  Federated Learning Simulation')
    print(f'  Rounds={num_rounds}  Clients={len(clients)}  '
          f'LocalEpochs={LOCAL_EPOCHS}  LR={LEARNING_RATE}')
    print(f'{sep}')
    print(f'  {"Round":>5}  {"Avg Loss":>10}  {"Accuracy":>10}  {"Drift ‖Δw‖":>12}')
    print(f'{sep}')

    for t in range(1, num_rounds + 1):
        w_prev = w_global.copy()

        # ── Step 1 & 2: distribute global weights; clients train locally ──
        client_updates: List[Tuple[np.ndarray, int]] = []
        for client in clients:
            updated_params, n_samples, _ = client.fit(
                [w_global.copy()], config=fit_config
            )
            client_updates.append((updated_params[0], n_samples))

        # ── Step 3: FedAvg aggregation ────────────────────────────────────
        w_global = federated_average(client_updates)

        # ── Weight drift  ‖w_t − w_{t−1}‖₂ ──────────────────────────────
        # Measures how much the global model changed this round.
        # Converges toward 0 as the model stabilises.
        drift = float(np.linalg.norm(
            w_global.astype(np.float64) - w_prev.astype(np.float64)
        ))

        # ── Step 4: evaluate global model on all clients ──────────────────
        per_loss, per_acc = [], []
        for client in clients:
            loss, _, metrics = client.evaluate([w_global.copy()], config={})
            per_loss.append(loss)
            per_acc.append(metrics['accuracy'])

        avg_loss = float(np.mean(per_loss))
        avg_acc  = float(np.mean(per_acc))

        history['avg_loss'].append(avg_loss)
        history['avg_accuracy'].append(avg_acc)
        history['weight_drift'].append(drift)
        history['round_weights'].append(w_global.copy())
        history['per_client_loss'].append(per_loss)
        history['per_client_accuracy'].append(per_acc)

        print(f'  {t:>5}  {avg_loss:>10.4f}  {avg_acc:>10.4f}  {drift:>12.4f}')

    print(f'{sep}\n')
    return history


# ── Plotting ──────────────────────────────────────────────────────────────────

def plot_convergence(history: dict, output_path: Path) -> None:
    """
    Figure 1 — Model Convergence over FL Rounds  (convergence.png)

    Three panels:
      (A) MSE Loss — global model converging to weighted mean of clients.
          Shaded band shows min/max client loss, revealing heterogeneity.
      (B) Weight Drift ‖wₜ − wₜ₋₁‖₂ — magnitude of global updates per round.
          Approaches zero as the model stabilises (convergence criterion).
      (C) Agreement Accuracy — fraction of COCO classes where the global
          model and each client agree on whether the class is 'uncertain'.
    """
    rounds = history['rounds']
    colours = plt.rcParams['axes.prop_cycle'].by_key()['color']

    fig, axes = plt.subplots(1, 3, figsize=(15, 4.5))
    fig.suptitle('Model Convergence over FL Rounds', fontsize=14,
                 fontweight='bold', y=1.03)

    # ── Panel A: Loss ─────────────────────────────────────────────────────
    ax = axes[0]
    per_loss = np.array(history['per_client_loss'])   # shape (T, K)
    ax.plot(rounds, history['avg_loss'], 'o-',
            color=colours[0], linewidth=2, markersize=6,
            label='Avg loss (FedAvg)', zorder=3)
    ax.fill_between(rounds, per_loss.min(axis=1), per_loss.max(axis=1),
                    alpha=0.18, color=colours[0], label='Client min / max')
    ax.set_xlabel('FL Round')
    ax.set_ylabel('MSE   ½‖w − μᵢ‖²')
    ax.set_title('(A)  Convergence Loss', fontweight='bold')
    ax.legend(fontsize=9)
    ax.grid(True, alpha=0.3)
    ax.set_xticks(rounds)

    # ── Panel B: Weight drift ─────────────────────────────────────────────
    ax = axes[1]
    ax.bar(rounds, history['weight_drift'],
           color=colours[1], alpha=0.85, edgecolor='white')
    ax.set_xlabel('FL Round')
    ax.set_ylabel('‖wₜ − wₜ₋₁‖₂')
    ax.set_title('(B)  Global Weight Drift', fontweight='bold')
    ax.grid(True, axis='y', alpha=0.3)
    ax.set_xticks(rounds)

    # ── Panel C: Accuracy ─────────────────────────────────────────────────
    ax = axes[2]
    per_acc = np.array(history['per_client_accuracy'])
    ax.plot(rounds, history['avg_accuracy'], 's-',
            color=colours[2], linewidth=2, markersize=6,
            label='Avg accuracy', zorder=3)
    ax.fill_between(rounds, per_acc.min(axis=1), per_acc.max(axis=1),
                    alpha=0.18, color=colours[2], label='Client min / max')
    ax.set_xlabel('FL Round')
    ax.set_ylabel('Class-agreement accuracy')
    ax.set_title('(C)  Global–Local Class Agreement', fontweight='bold')
    ax.set_ylim(0, 1.05)
    ax.legend(fontsize=9)
    ax.grid(True, alpha=0.3)
    ax.set_xticks(rounds)

    plt.tight_layout()
    fig.savefig(output_path, dpi=150, bbox_inches='tight')
    print(f'  Saved → {output_path}')
    plt.close(fig)


def plot_client_distributions(
    clients: List[FlowerClient],
    final_global_weights: np.ndarray,
    output_path: Path,
) -> None:
    """
    Figure 2 — Client Weight Distribution  (distributions.png)

    Panel (A): Heatmap — rows = clients, columns = top-20 most variable COCO
    classes.  Colour intensity shows mean class-activation score, revealing
    each client's unique visual environment.

    Panel (B): Grouped bar chart — top-8 classes by global FedAvg weight.
    Each bar group shows per-client local means alongside the global model,
    demonstrating how FedAvg bridges heterogeneous client distributions.
    """
    client_means = np.stack([c.local_mean for c in clients])  # (K, 80)
    client_names = [c.name for c in clients]

    # Select the 20 most variable classes across clients (highest variance).
    # These are the classes that best distinguish different user environments.
    top20_idx = np.argsort(client_means.var(axis=0))[::-1][:20]
    top20_labels = [COCO_CLASSES[i] for i in top20_idx]

    fig, axes = plt.subplots(1, 2, figsize=(18, 6))
    fig.suptitle('Client Class-Activation Weight Distribution',
                 fontsize=14, fontweight='bold', y=1.03)

    # ── Panel A: Heatmap ──────────────────────────────────────────────────
    ax = axes[0]
    heat_data = client_means[:, top20_idx]  # (K, 20)
    im = ax.imshow(heat_data, aspect='auto', cmap='YlOrRd', vmin=0.0, vmax=0.5)
    ax.set_xticks(range(len(top20_labels)))
    ax.set_xticklabels(top20_labels, rotation=45, ha='right', fontsize=8)
    ax.set_yticks(range(len(client_names)))
    ax.set_yticklabels(client_names, fontsize=9)
    ax.set_title('(A)  Per-Client Mean Activation Heatmap\n'
                 '(top 20 classes by cross-client variance)', fontweight='bold')
    cbar = plt.colorbar(im, ax=ax)
    cbar.set_label('Mean class-activation score')

    # Annotate each cell with its value for thesis readability.
    for row in range(len(client_names)):
        for col in range(len(top20_labels)):
            val = heat_data[row, col]
            text_colour = 'white' if val > 0.35 else 'black'
            ax.text(col, row, f'{val:.2f}', ha='center', va='center',
                    fontsize=6.5, color=text_colour)

    # ── Panel B: Grouped bar chart ─────────────────────────────────────────
    ax = axes[1]

    # Top-8 classes by final global weight (highest-priority in the global prior).
    top8_idx = np.argsort(final_global_weights)[::-1][:8]
    top8_labels = [COCO_CLASSES[i] for i in top8_idx]

    x = np.arange(len(top8_labels))
    bar_width = 0.08
    colour_map = plt.cm.tab10(np.linspace(0.0, 0.85, len(clients)))

    for k, (client, colour) in enumerate(zip(clients, colour_map)):
        offset = x + (k - (len(clients) - 1) / 2) * bar_width
        ax.bar(offset, client.local_mean[top8_idx],
               width=bar_width, color=colour, alpha=0.82, label=client.name)

    # Overlay the global FedAvg model as a line.
    ax.plot(x, final_global_weights[top8_idx], 'k^--',
            markersize=9, linewidth=1.8, label='Global model (FedAvg)', zorder=5)

    ax.set_xticks(x)
    ax.set_xticklabels(top8_labels, rotation=30, ha='right', fontsize=9)
    ax.set_ylabel('Class-activation weight')
    ax.set_title('(B)  Global Model vs. Per-Client Weights\n'
                 '(top 8 classes by global weight)', fontweight='bold')
    ax.legend(fontsize=7.5, ncol=2, loc='upper right')
    ax.grid(True, axis='y', alpha=0.3)
    ax.set_ylim(0.0, 0.58)

    plt.tight_layout()
    fig.savefig(output_path, dpi=150, bbox_inches='tight')
    print(f'  Saved → {output_path}')
    plt.close(fig)


# ── Entry point ───────────────────────────────────────────────────────────────

def main() -> None:
    parser = argparse.ArgumentParser(
        description='FAVS FL Simulation — Flower (flwr) framework',
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )
    parser.add_argument('--rounds',    type=int, default=NUM_ROUNDS,
                        help='Number of FL rounds to simulate.')
    parser.add_argument('--clients',   type=int, default=NUM_CLIENTS,
                        help='Number of virtual clients.')
    parser.add_argument('--samples',   type=int, default=SAMPLES_PER_CLIENT,
                        help='Synthetic samples per client (ignored with --real-data).')
    parser.add_argument('--real-data', action='store_true',
                        help='Load real on-device samples from fl_samples/ if present.')
    args = parser.parse_args()

    script_dir  = Path(__file__).parent
    samples_dir = (script_dir.parent / 'fl_samples') if args.real_data else None
    plots_dir   = script_dir / 'plots'
    plots_dir.mkdir(exist_ok=True)

    # ── 1. Load / generate data ───────────────────────────────────────────
    print(f'\nSmart Vision Assist — FL Simulation')
    print(f'Flower version: {fl.__version__}')
    datasets = load_or_generate_data(args.samples, samples_dir)
    datasets = datasets[:args.clients]

    # ── 2. Build Flower clients ───────────────────────────────────────────
    clients = [FlowerClient(name=name, local_data=data) for name, data in datasets]

    print(f'\n{len(clients)} client(s) ready:')
    for c in clients:
        print(f'  {c.name:28s}  n={len(c.local_data):3d}  '
              f'‖μᵢ‖={np.linalg.norm(c.local_mean):.3f}')

    # ── 3. Run simulation ─────────────────────────────────────────────────
    history = run_simulation(clients, num_rounds=args.rounds)

    # ── 4. Print summary ──────────────────────────────────────────────────
    loss_0   = history['avg_loss'][0]
    loss_T   = history['avg_loss'][-1]
    pct      = (loss_0 - loss_T) / loss_0 * 100 if loss_0 > 0 else 0
    print('Simulation summary:')
    print(f'  Initial loss   : {loss_0:.4f}')
    print(f'  Final loss     : {loss_T:.4f}  ({pct:.1f}% reduction)')
    print(f'  Final accuracy : {history["avg_accuracy"][-1]:.4f}')
    print(f'  Cumulative drift: {sum(history["weight_drift"]):.4f}')

    # ── 5. Save plots ─────────────────────────────────────────────────────
    final_weights = history['round_weights'][-1]
    print(f'\nGenerating plots → {plots_dir}/')
    plot_convergence(history, plots_dir / 'convergence.png')
    plot_client_distributions(clients, final_weights, plots_dir / 'distributions.png')

    print('\nDone.')


if __name__ == '__main__':
    main()
