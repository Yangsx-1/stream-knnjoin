/* Parially adapted from cuNSearch (https://github.com/InteractiveComputerGraphics/cuNSearch),
   especially https://github.com/InteractiveComputerGraphics/cuNSearch/blob/master/src/cuNSearchKernels.cu */

#include <sutil/vec_math.h>

#include "helper_mortonCode.h"
#include "helper_linearIndex.h"
#include "grid.h"

#include <stdio.h>

/* GPU code */
inline __host__ __device__ uint ToCellIndex_MortonMetaGrid(const GridInfo &GridInfo, int3 gridCell)
{
  //int3 temp = gridCell;

  int3 metaGridCell = make_int3(
    gridCell.x / GridInfo.meta_grid_dim,
    gridCell.y / GridInfo.meta_grid_dim,
    gridCell.z / GridInfo.meta_grid_dim);

  gridCell.x %= GridInfo.meta_grid_dim;
  gridCell.y %= GridInfo.meta_grid_dim;
  gridCell.z %= GridInfo.meta_grid_dim;
  uint metaGridIndex = CellIndicesToLinearIndex(GridInfo.MetaGridDimension, metaGridCell);

  //if (temp.x == 283 && temp.y == 10 && temp.z == 418)
  //  printf("(%d, %d, %d), (%d, %d, %d), %u, %u, %u\n", metaGridCell.x, metaGridCell.y, metaGridCell.z, gridCell.x, gridCell.y, gridCell.z, metaGridIndex, metaGridIndex * GridInfo.meta_grid_size, MortonCode3(gridCell.x, gridCell.y, gridCell.z));

  return metaGridIndex * GridInfo.meta_grid_size + MortonCode3(gridCell.x, gridCell.y, gridCell.z);
}

inline __host__ __device__
float getWidthFromIter(int iter, float cellSize) {
  // to be absolutely certain, we add 2 (not 1) to iter to accommodate points
  // at the edges of the central cell. width means there are K points within
  // the width^3 AABB, whose center is the center point of the current cell.
  // for corner points in the cell, its width^3 AABB might have less than count
  // # of points if the point distrition becomes dramatically sparse outside of
  // the current AABB. we empirically observe no issue with >1M points, but
  // with about ~100K points this could be an issue.

  return (iter * 2 + 2) * cellSize;
}

inline __host__ __device__
unsigned int getCellIdx(GridInfo gridInfo, int ix, int iy, int iz, bool morton) {
  if (morton) // z-order sort
    return ToCellIndex_MortonMetaGrid(gridInfo, make_int3(ix, iy, iz));
  else // raster order
    return (ix * gridInfo.GridDimension.y + iy) * gridInfo.GridDimension.z + iz;
}

inline __host__ __device__
bool oob(GridInfo gridInfo, int ix, int iy, int iz) { // out of boundary
  if (ix < 0 || ix >= (int)gridInfo.GridDimension.x
   || iy < 0 || iy >= (int)gridInfo.GridDimension.y
   || iz < 0 || iz >= (int)gridInfo.GridDimension.z)
    return true;
  else return false;
}

inline __host__ __device__
void addCount(unsigned int& count, unsigned int* CellParticleCounts, GridInfo gridInfo, int ix, int iy, int iz, bool morton) {
    if (oob(gridInfo, ix, iy, iz)) return;

    // TODO: weird bug using nvcc V10.0.130, Driver Version: 470.42.01, and CUDA Version: 11.4
    // (https://forums.developer.nvidia.com/t/weird-bug-involving-the-way-to-pass-parameters-to-kernels/183890)
    // that the returned result from getCellIdx is incorrect.
    // Fixed when using nvcc 11.3/.4, which, however, doesn't compile with thrust v101201. manually downgrading thrust.

    //unsigned int iCellIdx = getCellIdx(gridInfo, ix, iy, iz, morton);
    int3 cell = make_int3(ix, iy, iz);
    unsigned int iCellIdx;
    if (morton)
      iCellIdx = ToCellIndex_MortonMetaGrid(gridInfo, cell);
    else
      iCellIdx = (cell.x * gridInfo.GridDimension.y + cell.y) * gridInfo.GridDimension.z + cell.z;

    count += CellParticleCounts[iCellIdx];
    //if (ix == 87 && iy == 22 && iz == 358) printf("[%d, %d, %d]\n", ix, iy, iz, iCellIdx);
}

__host__ __device__
void calcSearchSize(int3 gridCell,
                    GridInfo gridInfo,
                    bool morton, 
                    unsigned int* CellParticleCounts,
                    float cellSize,
                    float maxWidth,
                    unsigned int knn,
                    int* cellMask
                   ) {
  // important that x/y/z are ints not units, as we check oob when they become negative.
  int x = gridCell.x;
  int y = gridCell.y;
  int z = gridCell.z;

  // TODO: weird bug using nvcc V10.0.130, Driver Version: 470.42.01, and CUDA Version: 11.4
  // (https://forums.developer.nvidia.com/t/weird-bug-involving-the-way-to-pass-parameters-to-kernels/183890)
  // that the returned result from getCellIdx is incorrect.
  // Fixed when using nvcc 11.3/.4, which, however, doesn't compile with thrust v101201. manually downgrading thrust.

  //unsigned int cellIndex = getCellIdx(gridInfo, x, y, z, morton);
  unsigned int cellIndex;
  if (morton)
    cellIndex = ToCellIndex_MortonMetaGrid(gridInfo, gridCell);
  else
    cellIndex = (gridCell.x * gridInfo.GridDimension.y + gridCell.y) * gridInfo.GridDimension.z + gridCell.z;


  //if (x == 283 && y == 10 && z == 418) printf("cell %d has %d particles. morton? %d\n", cellIndex, CellParticleCounts[cellIndex], morton);
  //assert(cellIndex <= numberOfCells);
  //if (CellParticleCounts[cellIndex] == 0) return; // should never hit this.

  int iter = 0;
  unsigned int count = 0;
  addCount(count, CellParticleCounts, gridInfo, x, y, z, morton);

  int xmin = x;
  int xmax = x;
  int ymin = y;
  int ymax = y;
  int zmin = z;
  int zmax = z;
 
  while(1) {
    // TODO: there could be corner cases here, e.g., maxWidth is very
    // small, cellSize will be 0 (same as uninitialized).
    // TODO: another optimization we can do is what if a query is so far away
    // from the search points? right now those queries will fall into the last
    // batch and searched using the search radius. how can we skip searches for
    // them altogether by doing something here? for that we need a different
    // maxWidth that encloses the search sphere.
    float width = getWidthFromIter(iter, cellSize);
 
    if (width > maxWidth) {
      cellMask[cellIndex] = iter;
      break;
    }
    else if (count >= (knn + 1)) {
      // + 1 because the count in CellParticleCounts includes the point
      // itself whereas our KNN search isn't going to return itself!
      cellMask[cellIndex] = iter;
      break;
    }
    else {
      iter++;
    }
 
    int ix, iy, iz;
 
    iz = zmin - 1;
    for (ix = xmin; ix <= xmax; ix++) {
      for (iy = ymin; iy <= ymax; iy++) {
        addCount(count, CellParticleCounts, gridInfo, ix, iy, iz, morton);
      }
    }
 
    iz = zmax + 1;
    for (ix = xmin; ix <= xmax; ix++) {
      for (iy = ymin; iy <= ymax; iy++) {
        addCount(count, CellParticleCounts, gridInfo, ix, iy, iz, morton);
      }
    }

    ix = xmin - 1;
    for (iy = ymin; iy <= ymax; iy++) {
      for (iz = zmin; iz <= zmax; iz++) {
        addCount(count, CellParticleCounts, gridInfo, ix, iy, iz, morton);
      }
    }

    ix = xmax + 1;
    for (iy = ymin; iy <= ymax; iy++) {
      for (iz = zmin; iz <= zmax; iz++) {
        addCount(count, CellParticleCounts, gridInfo, ix, iy, iz, morton);
      }
    }
 
    iy = ymin - 1;
    for (ix = xmin; ix <= xmax; ix++) {
      for (iz = zmin; iz <= zmax; iz++) {
        addCount(count, CellParticleCounts, gridInfo, ix, iy, iz, morton);
      }
    }
 
    iy = ymax + 1;
    for (ix = xmin; ix <= xmax; ix++) {
      for (iz = zmin; iz <= zmax; iz++) {
        addCount(count, CellParticleCounts, gridInfo, ix, iy, iz, morton);
      }
    }
 
    xmin--;
    xmax++;
    ymin--;
    ymax++;
    zmin--;
    zmax++;
 
    addCount(count, CellParticleCounts, gridInfo, xmin, ymin, zmin, morton);
    addCount(count, CellParticleCounts, gridInfo, xmin, ymin, zmax, morton);
    addCount(count, CellParticleCounts, gridInfo, xmin, ymax, zmin, morton);
    addCount(count, CellParticleCounts, gridInfo, xmin, ymax, zmax, morton);
    addCount(count, CellParticleCounts, gridInfo, xmax, ymin, zmin, morton);
    addCount(count, CellParticleCounts, gridInfo, xmax, ymin, zmax, morton);
    addCount(count, CellParticleCounts, gridInfo, xmax, ymax, zmin, morton);
    addCount(count, CellParticleCounts, gridInfo, xmax, ymax, zmax, morton);
  }
}

__global__ void kComputeMinMax(
  const float3 *particles,
  unsigned int particleCount,
  int3 *minCell,
  int3 *maxCell
)
{
  unsigned int particleIndex = blockIdx.x * blockDim.x + threadIdx.x;
  if (particleIndex >= particleCount) return;
  const float3 particle = particles[particleIndex];

  int3 cell;
  // convert float to int since atomicMin/Max has no native float version
  // TODO: mind the float to int conversion issue
  cell.x = (int)floorf(particle.x); // floorf returns a float
  cell.y = (int)floorf(particle.y);
  cell.z = (int)floorf(particle.z);

  atomicMin(&(minCell->x), cell.x);
  atomicMin(&(minCell->y), cell.y);
  atomicMin(&(minCell->z), cell.z);

  atomicMax(&(maxCell->x), cell.x);
  atomicMax(&(maxCell->y), cell.y);
  atomicMax(&(maxCell->z), cell.z);

  //printf("%d %d %d Min: %d %d %d Max: %d %d %d \n", cell.x, cell.y, cell.z, minCell->x, minCell->y, minCell->z, maxCell->x, maxCell->y, maxCell->z);
}

__global__ void kInsertParticles_Raster(
  const GridInfo GridInfo,
  const float3 *particles,
  unsigned int *particleCellIndices,
  unsigned int *cellParticleCounts,
  unsigned int *localSortedIndices
)
{
  unsigned int particleIndex = blockIdx.x * blockDim.x + threadIdx.x;
  if (particleIndex >= GridInfo.ParticleCount) return;
  //printf("%u, %u\n", particleIndex, GridInfo.ParticleCount);

  float3 gridCellF = (particles[particleIndex] - GridInfo.GridMin) * GridInfo.GridDelta;
  int3 gridCell = make_int3(int(gridCellF.x), int(gridCellF.y), int(gridCellF.z));

  unsigned int cellIndex = (gridCell.x * GridInfo.GridDimension.y + gridCell.y) * GridInfo.GridDimension.z + gridCell.z;
  if (particleCellIndices)
    particleCellIndices[particleIndex] = cellIndex;

  //float3 query = particles[particleIndex];
  //float3 b = make_float3(-57.230999, 2.710000, 9.608000);
  //if (fabs(query.x - b.x) < 0.001 && fabs(query.y - b.y) < 0.001 && fabs(query.z - b.z) < 0.001) {
  //  printf("particle [%f, %f, %f], [%d, %d, %d] in cell %u\n", query.x, query.y, query.z, gridCell.x, gridCell.y, gridCell.z, cellIndex);
  //}

  // this stores the within-cell sorted indices of particles
  if (localSortedIndices)
    localSortedIndices[particleIndex] = atomicAdd(&cellParticleCounts[cellIndex], 1);
  else // if localSortedIndices is nullptr, we still need to increment cellParticleCounts
    atomicAdd(&cellParticleCounts[cellIndex], 1);

  //if (cellIndex == 6054598)
  //  printf("cell 6054598 has %u particles [%f, %f, %f]. Dist: %f\n", cellParticleCounts[cellIndex], query.x, query.y, query.z, sqrt((query.x - b.x) * (query.x - b.x) + (query.y - b.y) * (query.y - b.y) + (query.z - b.z) * (query.z - b.z)));

  //printf("%u, %u, (%d, %d, %d)\n", particleIndex, cellIndex, gridCell.x, gridCell.y, gridCell.z);
}

__global__ void kInsertParticles_Morton(
  const GridInfo GridInfo,
  const float3 *particles,
  unsigned int *particleCellIndices,
  unsigned int *cellParticleCounts,
  unsigned int *localSortedIndices
)
{
  unsigned int particleIndex = blockIdx.x * blockDim.x + threadIdx.x;
  if (particleIndex >= GridInfo.ParticleCount) return;

  float3 gridCellF = (particles[particleIndex] - GridInfo.GridMin) * GridInfo.GridDelta;
  int3 gridCell = make_int3(int(gridCellF.x), int(gridCellF.y), int(gridCellF.z));

  unsigned int cellIndex = ToCellIndex_MortonMetaGrid(GridInfo, gridCell);
  if (particleCellIndices)
    particleCellIndices[particleIndex] = cellIndex;

  //float3 query = particles[particleIndex];
  //float3 b = make_float3(21.618000, -0.005000, -13.505000);
  //if (fabs(query.x - b.x) < 0.001 && fabs(query.y - b.y) < 0.001 && fabs(query.z - b.z) < 0.001) {
  //  printf("particle [%f, %f, %f], [%d, %d, %d] in cell %u\n", query.x, query.y, query.z, gridCell.x, gridCell.y, gridCell.z, cellIndex);
  //}

  // this stores the within-cell sorted indices of particles
  if (localSortedIndices)
    localSortedIndices[particleIndex] = atomicAdd(&cellParticleCounts[cellIndex], 1);
  else // if localSortedIndices is nullptr, we still need to increment cellParticleCounts
    atomicAdd(&cellParticleCounts[cellIndex], 1);

  //printf("%u, %u, (%d, %d, %d)\n", particleIndex, cellIndex, gridCell.x, gridCell.y, gridCell.z);
}

__global__ void kCountingSortIndices(
  const GridInfo GridInfo,
  const uint* particleCellIndices,
  const uint* cellOffsets,
  const uint* localSortedIndices,
  uint* posInSortedPoints
)
{
  uint particleIndex = blockIdx.x * blockDim.x + threadIdx.x;
  if (particleIndex >= GridInfo.ParticleCount) return;

  uint gridCellIndex = particleCellIndices[particleIndex];

  uint sortIndex = localSortedIndices[particleIndex] + cellOffsets[gridCellIndex];
  posInSortedPoints[particleIndex] = sortIndex;

  //printf("%u, %u, %u, %u, %u\n", particleIndex, gridCellIndex, localSortedIndices[particleIndex], cellOffsets[gridCellIndex], sortIndex);
}

__global__ void kCountingSortIndices_setRayMask(
  const GridInfo GridInfo,
  const uint* particleCellIndices,
  const uint* cellOffsets,
  const uint* localSortedIndices,
  uint* posInSortedPoints,
  int* cellMask,
  int* rayMask
)
{
  uint particleIndex = blockIdx.x * blockDim.x + threadIdx.x;
  if (particleIndex >= GridInfo.ParticleCount) return;

  uint gridCellIndex = particleCellIndices[particleIndex];

  uint sortIndex = localSortedIndices[particleIndex] + cellOffsets[gridCellIndex];
  posInSortedPoints[particleIndex] = sortIndex;

  rayMask[particleIndex] = cellMask[gridCellIndex];

  //printf("%u, %u, %u, %u, %u\n", particleIndex, gridCellIndex, localSortedIndices[particleIndex], cellOffsets[gridCellIndex], sortIndex);
}

__global__ void kGenCellMask(GridInfo gridInfo,
                             bool morton, 
                             unsigned int* cellParticleCounts,
                             unsigned int* repQueries,
                             float3* particles,
                             float cellSize,
                             float maxWidth,
                             unsigned int knn,
                             int* cellMask
                            )
{
  uint particleIndex = blockIdx.x * blockDim.x + threadIdx.x;
  if (particleIndex >= gridInfo.ParticleCount) return;

  unsigned int qId = repQueries[particleIndex];
  float3 point = particles[qId];
  float3 gridCellF = (point - gridInfo.GridMin) * gridInfo.GridDelta;
  int3 gridCell = make_int3(int(gridCellF.x), int(gridCellF.y), int(gridCellF.z));

  calcSearchSize(gridCell,
                 gridInfo,
                 morton,
                 cellParticleCounts,
                 cellSize,
                 maxWidth,
                 knn,
                 cellMask
                );
}







/* CPU wrapper code */
void kComputeMinMax (unsigned int numOfBlocks, unsigned int threadsPerBlock, float3* points, unsigned int numPrims, int3* d_MinMax_0, int3* d_MinMax_1) {
  kComputeMinMax <<<numOfBlocks, threadsPerBlock>>> (
      points,
      numPrims,
      d_MinMax_0,
      d_MinMax_1
      );
}

void kInsertParticles(unsigned int numOfBlocks, unsigned int threadsPerBlock, GridInfo gridInfo, float3* points, unsigned int* d_ParticleCellIndices, unsigned int* d_CellParticleCounts, unsigned int* d_TempSortIndices, bool morton) {
  if (morton) {
    kInsertParticles_Morton <<<numOfBlocks, threadsPerBlock>>> (
        gridInfo,
        points,
        d_ParticleCellIndices,
        d_CellParticleCounts,
        d_TempSortIndices
        );
  } else {
    kInsertParticles_Raster <<<numOfBlocks, threadsPerBlock>>> (
        gridInfo,
        points,
        d_ParticleCellIndices,
        d_CellParticleCounts,
        d_TempSortIndices
        );
  }
}

void kCountingSortIndices(unsigned int numOfBlocks, unsigned int threadsPerBlock,
      GridInfo gridInfo,
      unsigned int* d_ParticleCellIndices,
      unsigned int* d_CellOffsets,
      unsigned int* d_LocalSortedIndices,
      unsigned int* d_posInSortedPoints
      ) {
  kCountingSortIndices <<<numOfBlocks, threadsPerBlock>>> (
      gridInfo,
      d_ParticleCellIndices,
      d_CellOffsets,
      d_LocalSortedIndices,
      d_posInSortedPoints
      );
}

void kCountingSortIndices_setRayMask(unsigned int numOfBlocks, unsigned int threadsPerBlock,
      GridInfo gridInfo,
      unsigned int* d_ParticleCellIndices,
      unsigned int* d_CellOffsets,
      unsigned int* d_LocalSortedIndices,
      unsigned int* d_posInSortedPoints,
      int* cellMask,
      int* rayMask
      ) {
  kCountingSortIndices_setRayMask <<<numOfBlocks, threadsPerBlock>>> (
      gridInfo,
      d_ParticleCellIndices,
      d_CellOffsets,
      d_LocalSortedIndices,
      d_posInSortedPoints,
      cellMask,
      rayMask
      );
}

void kCalcSearchSize(unsigned int numOfBlocks,
                     unsigned int threadsPerBlock,
                     GridInfo gridInfo,
                     bool morton, 
                     unsigned int* cellParticleCounts,
                     unsigned int* repQueries,
                     float3* particles,
                     float cellSize,
                     float maxWidth,
                     unsigned int knn,
                     int* cellMask
                    ) {
  kGenCellMask <<<numOfBlocks, threadsPerBlock>>> (
             gridInfo,
             morton,
             cellParticleCounts,
             repQueries,
             particles,
             cellSize,
             maxWidth,
             knn,
             cellMask
            );
}

float kGetWidthFromIter(int iter, float cellSize) {
  return getWidthFromIter(iter, cellSize);
}

__global__ void kTest(GridInfo gridInfo, int3 test, unsigned int* res, bool morton) {
  *res = getCellIdx(gridInfo, test.x, test.y, test.z, true);
}

void test(GridInfo gridInfo) {
  int3 test = make_int3(283, 10, 418);
  //unsigned int h_res_cpu = getCellIdx(gridInfo, test.x, test.y, test.z, true);
  //printf("%d\n", h_res_cpu);

  unsigned int* d_res;
  cudaMalloc(reinterpret_cast<void**>(&d_res),
               sizeof(unsigned int) );
  
  kTest<<<1, 1>>> (gridInfo, test, d_res, true);
  unsigned int h_res;
  cudaMemcpy(
              reinterpret_cast<void*>( &h_res ),
              d_res,
              sizeof( unsigned int ),
              cudaMemcpyDeviceToHost
  );
  printf("%d\n", h_res);
}
