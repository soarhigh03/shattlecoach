"""Minimal ST-GCN (Yan et al., AAAI 2018) for 17-COCO skeletons.

Reference: https://arxiv.org/abs/1801.07455
This is a from-scratch PyTorch reimplementation kept small (~0.3M params) so it
fits the poster's ~1.2MB FP32 budget. We use the static spatial adjacency only
(no partitioning strategy beyond identity + inward + outward) and standard 9x1
temporal convs.

Used by US-007 / US-008 (the same backbone is reused for the contender to ablate
the head architecture; for a TRULY different contender, swap to CTR-GCN or PoseC3D
in scorer_contender/).
"""
from __future__ import annotations
import torch
import torch.nn as nn
import torch.nn.functional as F


# COCO-17 skeleton edges (1-indexed in many references; we use 0-indexed here).
# Pairs match the SKELETON_EDGES in scripts/extract_pose.py.
COCO_EDGES = [
    (5, 7), (7, 9), (6, 8), (8, 10),
    (11, 13), (13, 15), (12, 14), (14, 16),
    (5, 6), (11, 12), (5, 11), (6, 12),
    (0, 1), (0, 2), (1, 3), (2, 4),
    (0, 5), (0, 6),  # nose to shoulders for connectivity
]
N_JOINTS = 17


def build_adjacency(num_joints: int = N_JOINTS, edges: list[tuple[int, int]] = COCO_EDGES) -> torch.Tensor:
    """Returns symmetrically normalized adjacency: D^-1/2 (A + I) D^-1/2, shape (J, J)."""
    A = torch.zeros(num_joints, num_joints)
    for i, j in edges:
        A[i, j] = 1.0
        A[j, i] = 1.0
    A += torch.eye(num_joints)
    deg = A.sum(dim=1)
    d_inv_sqrt = torch.diag(deg.pow(-0.5))
    return d_inv_sqrt @ A @ d_inv_sqrt


class STGCNBlock(nn.Module):
    """Spatial GCN + temporal 1D conv, with residual."""

    def __init__(self, in_ch: int, out_ch: int, t_kernel: int = 9, stride: int = 1):
        super().__init__()
        # Spatial conv = 1x1 conv on channels then multiply by A.
        self.spatial = nn.Conv2d(in_ch, out_ch, kernel_size=1)
        self.bn1 = nn.BatchNorm2d(out_ch)
        # Temporal conv on the T dimension only.
        pad = ((t_kernel - 1) // 2, 0)
        self.temporal = nn.Conv2d(
            out_ch, out_ch, kernel_size=(t_kernel, 1), stride=(stride, 1), padding=pad
        )
        self.bn2 = nn.BatchNorm2d(out_ch)
        self.drop = nn.Dropout2d(p=0.1)
        if stride == 1 and in_ch == out_ch:
            self.residual = nn.Identity()
        else:
            self.residual = nn.Sequential(
                nn.Conv2d(in_ch, out_ch, kernel_size=1, stride=(stride, 1)),
                nn.BatchNorm2d(out_ch),
            )

    def forward(self, x: torch.Tensor, A: torch.Tensor) -> torch.Tensor:
        # x: (B, C, T, J).
        # We multiply along the J axis by A (J, J). PyTorch's torch.matmul on
        # the last two dims does exactly this and exports as a vanilla MatMul
        # in ONNX, which TFLite (via onnx2tf) can convert losslessly. Earlier
        # versions used torch.einsum, but TFLite has no Einsum kernel.
        res = self.residual(x)
        h = self.spatial(x)  # (B, C', T, J)
        h = torch.matmul(h, A)  # (B, C', T, J) @ (J, J) -> (B, C', T, J)
        h = F.relu(self.bn1(h))
        h = self.bn2(self.temporal(h))
        h = self.drop(h)
        return F.relu(h + res)


class STGCN(nn.Module):
    """5-block ST-GCN matching the poster's "5-layer ST-GCN (~0.3M params)" spec.

    Heads:
      - stroke_logits: classifier head over N_strokes classes (+ optional 'unknown').
      - criteria_logits: per-criterion binary head (5 logits).
    """

    def __init__(
        self,
        in_channels: int = 3,
        n_strokes: int = 4,
        n_criteria: int = 5,
        widths: tuple[int, ...] = (32, 32, 64, 64, 128),
    ):
        super().__init__()
        assert len(widths) == 5, "Poster specifies 5 layers"
        self.register_buffer("A", build_adjacency())
        self.input_bn = nn.BatchNorm1d(in_channels * N_JOINTS)

        chs = (in_channels,) + widths
        strides = (1, 1, 2, 1, 2)  # downsample T at blocks 3 and 5
        self.blocks = nn.ModuleList([
            STGCNBlock(chs[i], chs[i + 1], stride=strides[i]) for i in range(5)
        ])

        self.global_pool = nn.AdaptiveAvgPool2d(1)
        feat_dim = widths[-1]
        self.stroke_head = nn.Linear(feat_dim, n_strokes)
        self.criteria_head = nn.Linear(feat_dim, n_criteria)

    def forward(self, x: torch.Tensor) -> dict[str, torch.Tensor]:
        # x: (B, C, T, J) with C=3 (x, y, conf), T=frames, J=17
        B, C, T, J = x.shape
        # input batch norm over channel*joint
        x = x.permute(0, 1, 3, 2).contiguous().view(B, C * J, T)
        x = self.input_bn(x)
        x = x.view(B, C, J, T).permute(0, 1, 3, 2).contiguous()  # back to (B,C,T,J)

        for blk in self.blocks:
            x = blk(x, self.A)

        feat = self.global_pool(x).view(B, -1)
        return {
            "stroke_logits": self.stroke_head(feat),
            "criteria_logits": self.criteria_head(feat),
            "features": feat,
        }


def count_params(model: nn.Module) -> int:
    return sum(p.numel() for p in model.parameters() if p.requires_grad)


if __name__ == "__main__":
    m = STGCN()
    x = torch.randn(2, 3, 64, 17)
    out = m(x)
    print("params:", count_params(m))
    print({k: tuple(v.shape) for k, v in out.items()})
