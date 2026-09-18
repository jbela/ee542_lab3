import matplotlib.pyplot as plt
import numpy as np
import pandas as pd

df = pd.read_csv("network_data.csv")
pivoted_df = df.pivot(index="Loss (%)", columns="Delay (ms)", values="Throughput (Mbits/s)")

X, Y = np.meshgrid(pivoted_df.columns, pivoted_df.index)
Z = pivoted_df.values

fig, ax = plt.subplots(figsize=(9, 6))

cp = ax.contourf(X, Y, Z, levels=20, cmap="viridis")
cbar = fig.colorbar(cp)
cbar.set_label("Throughput (Mbits/s)")

# line_cp = ax.contour(X, Y, Z, levels=10, colors="black", linewidths=0.6) #contour lines
# ax.clabel(line_cp, inline=True, fontsize=8, fmt="%.1f")

ax.set_title("Throughput Contour Map by Delay & Loss")
ax.set_xlabel("Delay (ms)")
ax.set_ylabel("Loss (%)")

plt.tight_layout()
plt.show()