// ----------------------------------------------------------------
// Gunrock -- Fast and Efficient GPU Graph Library
// ----------------------------------------------------------------
// This source code is distributed under the terms of LICENSE.TXT
// in the root directory of this source distribution.
// ----------------------------------------------------------------

/**
 * @file
 * mst_enactor.cuh
 *
 * @brief MST Problem Enacotr
 */

#pragma once

#include <gunrock/util/kernel_runtime_stats.cuh>
#include <gunrock/util/test_utils.cuh>
#include <gunrock/util/sort_utils.cuh>
#include <gunrock/util/select_utils.cuh>
#include <gunrock/util/mark_segment.cuh>

#include <gunrock/oprtr/advance/kernel.cuh>
#include <gunrock/oprtr/advance/kernel_policy.cuh>
#include <gunrock/oprtr/filter/kernel.cuh>
#include <gunrock/oprtr/filter/kernel_policy.cuh>

#include <gunrock/app/enactor_base.cuh>
#include <gunrock/app/mst/mst_problem.cuh>
#include <gunrock/app/mst/mst_functor.cuh>

#include <moderngpu.cuh>
#include <limits>
#include <thrust/sort.h>

namespace gunrock {
namespace app {
namespace mst {

using namespace mgpu;

/**
 * @brief MST problem enactor class.
 *
 * @tparam INSTRUMWENT Boolean type to show whether or not
 * to collect per-CTA clock-count statistics
 */
template<bool INSTRUMENT>
class MSTEnactor : public EnactorBase
{
// Members
protected:

  /**
   * CTA duty kernel stats
   */

  unsigned long long total_runtimes;  // Total working time by each CTA
  unsigned long long total_lifetimes; // Total life time of each CTA
  unsigned long long total_queued;

  /**
   * A pinned, mapped word that the traversal kernels will signal when done
   */
  int          *vertex_flag;
  volatile int *done;
  int          *d_done;
  cudaEvent_t  throttle_event;

// Methods
protected:

  /**
   * @brief Prepare the enactor for MST kernel call.
   * Must be called prior to each MST iteration.
   *
   * @param[in] problem MST Problem object which holds the graph data and
   * MST problem data to compute.
   *
   * \return cudaError_t object which indicates the success of all CUDA calls.
   */
  template <typename ProblemData>
  cudaError_t Setup(ProblemData *problem)
  {
    typedef typename ProblemData::Value    Value;
    typedef typename ProblemData::VertexId VertexId;
    typedef typename ProblemData::SizeT    SizeT;

    cudaError_t retval = cudaSuccess;

    do
    {
      //initialize the host-mapped "done"
      if (!done)
      {
        int flags = cudaHostAllocMapped;

        // Allocate pinned memory for done
        if (retval = util::GRError(cudaHostAlloc(
          (void**)&done, sizeof(int) * 1, flags),
          "MSTEnactor cudaHostAlloc done failed",
          __FILE__, __LINE__)) break;

        // Map done into GPU space
        if (retval = util::GRError(cudaHostGetDevicePointer(
          (void**)&d_done, (void*) done, 0),
          "MSTEnactor cudaHostGetDevicePointer done failed",
          __FILE__, __LINE__)) break;

        // Create throttle event
        if (retval = util::GRError(cudaEventCreateWithFlags(
          &throttle_event, cudaEventDisableTiming),
          "MSTEnactor cudaEventCreateWithFlags throttle_event failed",
          __FILE__, __LINE__)) break;
      }

      /*
      // graph slice
      typename ProblemData::GraphSlice
        *graph_slice = problem->graph_slices[0];

      // moved to the begining of each iteration for efficiency
      // Bind row-offsets and bitmask texture
      cudaChannelFormatDesc row_offsets_desc = cudaCreateChannelDesc<SizeT>();
      if (retval = util::GRError(cudaBindTexture(
        0,
        gunrock::oprtr::edge_map_forward::RowOffsetTex<SizeT>::ref,
        graph_slice->d_row_offsets,
        row_offsets_desc,
        (graph_slice->nodes + 1) * sizeof(SizeT)),
        "MSTEnactor cudaBindTexture row_offset_tex_ref failed",
        __FILE__, __LINE__)) break;

      cudaChannelFormatDesc
        column_indices_desc = cudaCreateChannelDesc<VertexId>();
      if (retval = util::GRError(cudaBindTexture(
        0,
        gunrock::oprtr::edge_map_forward::ColumnIndicesTex<SizeT>::ref,
        graph_slice->d_column_indices,
        column_indices_desc,
        graph_slice->edges * sizeof(VertexId)),
        "MSTEnactor cudaBindTexture column_indices_tex_ref failed",
        __FILE__, __LINE__)) break;
      */

    } while (0);

    return retval;
  }

public:

  /**
   * @brief MSTEnactor constructor
   */
  MSTEnactor(bool DEBUG = false) :
    EnactorBase(EDGE_FRONTIERS, DEBUG),
    vertex_flag(NULL),
    done(NULL),
    d_done(NULL)
  {
    vertex_flag = new int;
    vertex_flag[0] = 0;
  }

  /**
   * @brief MSTEnactor destructor
   */
  virtual ~MSTEnactor()
  {
    if (vertex_flag) delete vertex_flag;
    if (done)
    {
      util::GRError(cudaFreeHost((void*)done),
        "MSTEnactor cudaFreeHost done failed",
        __FILE__, __LINE__);

      util::GRError(cudaEventDestroy(throttle_event),
        "MSTEnactor cudaEventDestroy throttle_event failed",
        __FILE__, __LINE__);
    }
  }

  /**
   * \addtogroup PublicInterface
   * @{
   */

  /**
   * @brief Obtain statistics about the last MST search enacted.
   *
   * @param[out] total_queued Total queued elements in MST kernel.
   * @param[out] search_depth Search depth of MST algorithm.
   * @param[out] avg_duty Average kernel running duty
   * (kernel run time/kernel lifetime).
   */
  template <typename VertexId>
  void GetStatistics(
    long long &total_queued,
    VertexId  &search_depth,
    double    &avg_duty)
  {
    cudaThreadSynchronize();

    total_queued = enactor_stats.total_queued;
    search_depth = enactor_stats.iteration;

    avg_duty = (enactor_stats.total_lifetimes > 0) ?
      double (enactor_stats.total_runtimes)/enactor_stats.total_lifetimes : 0.0;
  }

  /** @} */

  /**
   * @brief Enacts a MST computing on the specified graph.
   *
   * @tparam Advance Kernel policy for forward advance.
   * @tparam Filter Kernel policy for vertex mapping.
   * @tparam MSTProblem MST Problem type.
   *
   * @param[in] context CudaContext for moderngpu library
   * @param[in] problem MSTProblem object.
   * @param[in] max_grid_size Max grid size for MST kernel calls.
   *
   * \return cudaError_t object which indicates the success of
   * all CUDA function calls.
   */
  template<
    typename AdvanceKernelPolicy,
    typename FilterKernelPolicy,
    typename MSTProblem>
  cudaError_t EnactMST(
    CudaContext &context,
    MSTProblem  *problem,
    int         max_grid_size = 0)
  {
    typedef typename MSTProblem::VertexId VertexId;
    typedef typename MSTProblem::SizeT    SizeT;
    typedef typename MSTProblem::Value    Value;

    typedef SuccFunctor<
      VertexId,
      SizeT,
      VertexId,
      MSTProblem> SuccFunctor;

    typedef RmCycFunctor<
      VertexId,
      SizeT,
      VertexId,
      MSTProblem> RmCycFunctor;

    typedef PtrJumpFunctor<
      VertexId,
      SizeT,
      VertexId,
      MSTProblem> PtrJumpFunctor;

    typedef EdgeRmFunctor<
      VertexId,
      SizeT,
      VertexId,
      MSTProblem> EdgeRmFunctor;

    typedef RowOffsetsFunctor<
      VertexId,
      SizeT,
      VertexId,
      MSTProblem> RowOffsetsFunctor;

    typedef SuEdgeRmFunctor<
      VertexId,
      SizeT,
      VertexId,
      MSTProblem> SuEdgeRmFunctor;

    typedef OrFunctor<
      VertexId,
      SizeT,
      VertexId,
      MSTProblem> OrFunctor;

    typedef EdgeOffsetsFunctor<
      VertexId,
      SizeT,
      VertexId,
      MSTProblem> EdgeOffsetsFunctor;

    cudaError_t retval = cudaSuccess;

    unsigned int *d_scanned_edges = NULL;
    do
    {
      // initialization
      if (retval = Setup(problem)) break;
      if (retval = EnactorBase::Setup(
        problem,
        max_grid_size,
        AdvanceKernelPolicy::CTA_OCCUPANCY,
        FilterKernelPolicy::CTA_OCCUPANCY)) break;

      // single-gpu graph slice
      typename MSTProblem::GraphSlice *graph_slice = problem->graph_slices[0];
      typename MSTProblem::DataSlice  *data_slice  = problem->d_data_slices[0];

      if (AdvanceKernelPolicy::ADVANCE_MODE == gunrock::oprtr::advance::LB)
      {
        if (retval = util::GRError(cudaMalloc(
          (void**)&d_scanned_edges,
          graph_slice->edges * sizeof(unsigned int)),
          "MSTProblem cudaMalloc d_scanned_edges failed",
          __FILE__, __LINE__)) return retval;
      }

      // debug config
      //SizeT        num_edges_origin = graph_slice->edges;
      int          loop_limit = 0; // used for debug purpose
      bool         debug_info = 0; // used for debug purpose
      //int tmp_length = 0; // used for debug purpose
      //int tmp_select = 0; // used for debug purpose
      unsigned int *num_selected = new unsigned int; // used in cub::select

      //////////////////////////////////////////////////////////////////////////
      // recursive Loop for minimum spanning tree implementation
      while (graph_slice->nodes > 1)
      {
        if (DEBUG) printf("\nBEGIN ITERATION:%lld #NODES:%d #EDGES:%d\n",
          enactor_stats.iteration+1, graph_slice->nodes, graph_slice->edges);

        // bind row_offsets and bitmask texture for efficiency
        cudaChannelFormatDesc row_offsets_desc = cudaCreateChannelDesc<SizeT>();
        if (retval = util::GRError(cudaBindTexture(
          0,
          gunrock::oprtr::edge_map_forward::RowOffsetTex<SizeT>::ref,
          graph_slice->d_row_offsets,
          row_offsets_desc,
          (graph_slice->nodes + 1) * sizeof(SizeT)),
          "MSTEnactor cudaBindTexture row_offset_tex_ref failed",
          __FILE__, __LINE__)) break;

        if (debug_info)
        {
          printf(":: read in row_offsets ::");
          util::DisplayDeviceResults(
           graph_slice->d_row_offsets, graph_slice->nodes+1);
        }

        // generate d_flags_array from d_row_offsets using MarkSegment
        util::MemsetKernel<unsigned int><<<128, 128>>>(
          problem->data_slices[0]->d_flags_array, 0, graph_slice->edges);
        util::MarkSegmentFromIndices<<<128, 128>>>(
          problem->data_slices[0]->d_flags_array,
          graph_slice->d_row_offsets,
          graph_slice->nodes);

        if (DEBUG) printf("* finished mark segmentation: d_flags_array.\n");

        // generate d_keys_array from d_flags_array using sum inclusive scan
        Scan<MgpuScanTypeInc>(
          (int*)problem->data_slices[0]->d_flags_array, graph_slice->edges,
          (int)0, mgpu::plus<int>(), (int*)0, (int*)0,
          (int*)problem->data_slices[0]->d_keys_array, context);

        if (DEBUG) printf("* finished segmented sum scan: d_keys_array.\n");
        if (DEBUG) printf("A. MARKING THE MST EDGES ...\n");
        if (DEBUG) printf(" a. Finding Minimum Weighted Edges\n");

        ////////////////////////////////////////////////////////////////////////
        // each vertex u ﬁnds the minimum weighted edge to another vertex v
        // select minimum edge_weights and keys using ReduceByKey
        int num_segments;
        ReduceByKey(
          problem->data_slices[0]->d_keys_array,
          problem->data_slices[0]->d_edge_weights,
          graph_slice->edges,
          std::numeric_limits<int>::max(),
          mgpu::minimum<int>(),
          mgpu::equal_to<int>(),
          problem->data_slices[0]->d_reduced_keys,
          problem->data_slices[0]->d_reduced_vals,
          &num_segments, (int*)0, context);

        if (DEBUG) printf("  * finished segmented reduction: keys & weight.\n");

        if (debug_info)
        {
          printf(":: origin d_flags_array ::");
          util::DisplayDeviceResults(
            problem->data_slices[0]->d_flags_array, graph_slice->edges);
          printf(":: origin d_keys_array ::");
          util::DisplayDeviceResults(
            problem->data_slices[0]->d_keys_array, graph_slice->edges);
          printf(":: origin d_col_indices ::");
          util::DisplayDeviceResults(
            graph_slice->d_column_indices, graph_slice->edges);
          printf(":: origin d_edge_weights ::");
          util::DisplayDeviceResults(
            problem->data_slices[0]->d_edge_weights, graph_slice->edges);
          printf(":: reduced kes array - d_reduced_keys ::");
          util::DisplayDeviceResults(
            problem->data_slices[0]->d_reduced_keys, num_segments);
          printf(":: reduced edge weights - d_reduced_vals ::");
          util::DisplayDeviceResults(
            problem->data_slices[0]->d_reduced_vals, num_segments);
        }

        if (DEBUG) printf(" (b). Finding and Removing Cycles.\n");

        ////////////////////////////////////////////////////////////////////////
        // generate successor array using SuccFunctor - edge mapping
        // successor array holds the outgoing v for each u
        frontier_attribute.queue_index  = 0;
        frontier_attribute.selector     = 0;
        frontier_attribute.queue_length = graph_slice->nodes;
        frontier_attribute.queue_reset  = true;

        util::MemsetKernel<<<128, 128>>>(
          problem->data_slices[0]->d_successors,
          std::numeric_limits<int>::max(), graph_slice->nodes);

        gunrock::oprtr::advance::LaunchKernel
          <AdvanceKernelPolicy, MSTProblem, SuccFunctor>(
          d_done,
          enactor_stats,
          frontier_attribute,
          data_slice,
          (VertexId*)NULL,
          (bool*)NULL,
          (bool*)NULL,
          d_scanned_edges,
          graph_slice->frontier_queues.d_keys[frontier_attribute.selector],
          graph_slice->frontier_queues.d_keys[frontier_attribute.selector^1],
          (VertexId*)NULL,
          (VertexId*)NULL,
          graph_slice->d_row_offsets,
          graph_slice->d_column_indices,
          (SizeT*)NULL,
          (VertexId*)NULL,
          graph_slice->frontier_elements[frontier_attribute.selector],
          graph_slice->frontier_elements[frontier_attribute.selector^1],
          this->work_progress,
          context,
          gunrock::oprtr::advance::V2V);

        if (DEBUG && (retval = util::GRError(cudaThreadSynchronize(),
          "advance::Kernel failed", __FILE__, __LINE__))) break;

        if (DEBUG) printf("  * finished minimum weighted edges: successors.\n");

        if (debug_info)
        {
          printf(":: successor array ::");
          util::DisplayDeviceResults(
            problem->data_slices[0]->d_successors, graph_slice->nodes);
        }

        ////////////////////////////////////////////////////////////////////////
        // remove cycles - vertives with S(S(u)) = u forms cycles
        frontier_attribute.queue_index  = 0;
        frontier_attribute.selector     = 0;
        frontier_attribute.queue_length = graph_slice->nodes;
        frontier_attribute.queue_reset  = true;

        gunrock::oprtr::advance::LaunchKernel
          <AdvanceKernelPolicy, MSTProblem, RmCycFunctor>(
          d_done,
          enactor_stats,
          frontier_attribute,
          data_slice,
          (VertexId*)NULL,
          (bool*)NULL,
          (bool*)NULL,
          d_scanned_edges,
          graph_slice->frontier_queues.d_keys[frontier_attribute.selector],
          graph_slice->frontier_queues.d_keys[frontier_attribute.selector^1],
          (VertexId*)NULL,
          (VertexId*)NULL,
          graph_slice->d_row_offsets,
          graph_slice->d_column_indices,
          (SizeT*)NULL,
          (VertexId*)NULL,
          graph_slice->frontier_elements[frontier_attribute.selector],
          graph_slice->frontier_elements[frontier_attribute.selector^1],
          this->work_progress,
          context,
          gunrock::oprtr::advance::V2E);

        if (DEBUG && (retval = util::GRError(cudaThreadSynchronize(),
          "advance::Kernel failed", __FILE__, __LINE__))) break;

        if (DEBUG) printf("  * finished removing cycles: new successors.\n");

        if (debug_info)
        {
          printf(":: remove cycles from successors ::");
          util::DisplayDeviceResults(
            problem->data_slices[0]->d_successors, graph_slice->nodes);
        }

        if (DEBUG) printf("B. GRAPH CONSTRUCTION ...\n");
        if (DEBUG) printf(" (a). Merging Vertices\n");
        ////////////////////////////////////////////////////////////////////////
        // Then, we combine vertices to form a supervertex by employing
        // pointer doubling to achieve this result, iteratively setting
        // S(u) = S(S(u)) until no further change occurs in S
        // using vertex mapping: PtrJumpFunctor
        frontier_attribute.queue_index  = 0;
        frontier_attribute.selector     = 0;
        frontier_attribute.queue_length = graph_slice->nodes;
        frontier_attribute.queue_reset  = true;

        vertex_flag[0] = 0;
        while (!vertex_flag[0])
        {
          vertex_flag[0] = 1;
          if (retval = util::GRError(cudaMemcpy(
            problem->data_slices[0]->d_vertex_flag,
            vertex_flag,
            sizeof(int),
            cudaMemcpyHostToDevice),
            "MSTProblem cudaMemcpy vertex_flag to d_vertex_flag failed",
            __FILE__, __LINE__)) return retval;

          gunrock::oprtr::filter::Kernel
            <FilterKernelPolicy, MSTProblem, PtrJumpFunctor>
            <<<enactor_stats.filter_grid_size, FilterKernelPolicy::THREADS>>>(
              enactor_stats.iteration+1,
              frontier_attribute.queue_reset,
              frontier_attribute.queue_index,
              enactor_stats.num_gpus,
              frontier_attribute.queue_length,
              NULL,
              graph_slice->frontier_queues.d_keys[frontier_attribute.selector],
              NULL,
              graph_slice->frontier_queues.d_keys[frontier_attribute.selector^1],
              data_slice,
              NULL,
              work_progress,
              graph_slice->frontier_elements[frontier_attribute.selector],
              graph_slice->frontier_elements[frontier_attribute.selector^1],
              enactor_stats.filter_kernel_stats);

          if (DEBUG && (retval = util::GRError(cudaThreadSynchronize(),
            "filter::Kernel PointerJumping failed", __FILE__, __LINE__))) break;

          // prepare for next iteration, only reset once
          if (frontier_attribute.queue_reset)
          {
            frontier_attribute.queue_reset = false;
          }
          frontier_attribute.queue_index++;
          frontier_attribute.selector^=1;

          if (retval = util::GRError(cudaMemcpy(
            vertex_flag,
            problem->data_slices[0]->d_vertex_flag,
            sizeof(int),
            cudaMemcpyDeviceToHost),
            "MSTProblem cudaMemcpy d_vertex_flag to vertex_flag failed",
            __FILE__, __LINE__)) return retval;

          // check if finished pointer jumpping
          if (vertex_flag[0]) break;
        }

        if (DEBUG) printf("  * finished pointer doubling: representatives.\n");
        if (DEBUG) printf(" (b).Assigning IDs to Supervertices\n");
        ////////////////////////////////////////////////////////////////////////
        // each vertex of a supervertex now has a representative, but the
        // supervertices are not numbered in order. The vertices assigned
        // to a supervertex are also not placed in order in the successor

        // bring all vertices of a supervertex together by sorting
        util::MemsetCopyVectorKernel<<<128, 128>>>(
          problem->data_slices[0]->d_super_vids,
          problem->data_slices[0]->d_successors,
          graph_slice->nodes);

        util::MemsetIdxKernel<<<128, 128>>>(
        problem->data_slices[0]->d_origin_nodes, graph_slice->nodes);

        util::CUBRadixSort<VertexId, VertexId>(
          true,
          graph_slice->nodes,
          problem->data_slices[0]->d_super_vids,
          problem->data_slices[0]->d_origin_nodes);

        if (debug_info)
        {
          printf(":: pointer jumping: representatives ::");
          util::DisplayDeviceResults(
            problem->data_slices[0]->d_successors, graph_slice->nodes);
          printf(":: bring all vertices of a supervertex together ::");
          util::DisplayDeviceResults(
            problem->data_slices[0]->d_super_vids, graph_slice->nodes);
        }

        ////////////////////////////////////////////////////////////////////////
        // create a flag to mark the boundaries of representative vertices
        util::MarkSegmentFromKeys<<<128, 128>>>(
          problem->data_slices[0]->d_flags_array,
          problem->data_slices[0]->d_super_vids,
          graph_slice->nodes);

        if (DEBUG) printf("  * finished mark supervertices: super flags.\n");

        ////////////////////////////////////////////////////////////////////////
        // sum scan of the super flags to assign new supervertex ids
        Scan<MgpuScanTypeInc>(
          (int*)problem->data_slices[0]->d_flags_array, graph_slice->nodes,
          (int)0, mgpu::plus<int>(), (int*)0, (int*)0,
          (int*)problem->data_slices[0]->d_super_vids, context);

        if (DEBUG) printf("  * finished assign supervertex: d_super_vids.\n");

        if (debug_info)
        {
          printf(":: super flags (a.k.a. c flag) ::");
          util::DisplayDeviceResults(
            problem->data_slices[0]->d_flags_array, graph_slice->nodes);
          printf(":: new assigned supervertex ids ::");
          util::DisplayDeviceResults(
            problem->data_slices[0]->d_super_vids, graph_slice->nodes);
        }

        ////////////////////////////////////////////////////////////////////////
        // used for finding supervertex ids for next iteration
        util::CUBRadixSort<VertexId, VertexId>(
          true,
          graph_slice->nodes,
          problem->data_slices[0]->d_origin_nodes,
          problem->data_slices[0]->d_super_vids);

        ////////////////////////////////////////////////////////////////////////
        // update graph_slice->nodes with number of supervertices
        SizeT current_nodes = graph_slice->nodes;
        // the first segment in flag was set to 0 instead of 1
        util::MemsetKernel<unsigned int><<<1, 1>>>(
          problem->data_slices[0]->d_flags_array, 1, 1);
        graph_slice->nodes = Reduce(
          problem->data_slices[0]->d_flags_array, graph_slice->nodes, context);

        if (DEBUG)
          printf("  * finished update #nodes: %d left.\n", graph_slice->nodes);

        // terminate the loop if there is only one supervertex left
        if (graph_slice->nodes == 1)
        {
          printf("TERMINATE THE MST ALGORITHM ENACTOR.\n"); break;
        }

        if (DEBUG) printf(" (c). Removing Edges & Forming the new Edge List\n");
        ////////////////////////////////////////////////////////////////////////
        // shorten the edge list by removing self edges in the new graph
        // advance edge mapping remove edges belonging to the same supervertex
        // each edge examines the supervertex id of both end vertices and
        // removes itself if the id is the same
        frontier_attribute.queue_index  = 0;
        frontier_attribute.selector     = 0;
        frontier_attribute.queue_length = current_nodes;
        frontier_attribute.queue_reset  = true;

        gunrock::oprtr::advance::LaunchKernel
          <AdvanceKernelPolicy, MSTProblem, EdgeRmFunctor>(
          d_done,
          enactor_stats,
          frontier_attribute,
          data_slice,
          (VertexId*)NULL,
          (bool*)NULL,
          (bool*)NULL,
          d_scanned_edges,
          graph_slice->frontier_queues.d_values[frontier_attribute.selector],
          graph_slice->frontier_queues.d_values[frontier_attribute.selector^1],
          (VertexId*)NULL,
          (VertexId*)NULL,
          graph_slice->d_row_offsets,
          graph_slice->d_column_indices,
          (SizeT*)NULL,
          (VertexId*)NULL,
          graph_slice->frontier_elements[frontier_attribute.selector],
          graph_slice->frontier_elements[frontier_attribute.selector^1],
          this->work_progress,
          context,
          gunrock::oprtr::advance::V2V);

        if (DEBUG && (retval = util::GRError(cudaThreadSynchronize(),
          "advance::Kernel failed", __FILE__, __LINE__))) break;

        if (DEBUG) printf("  * finished mark edges in same supervertex.\n");

        ////////////////////////////////////////////////////////////////////////
        // filter to remove all -1 in d_col_indices
        util::MemsetCopyVectorKernel<<<128, 128>>>(
          problem->data_slices[0]->d_temp_storage,
          problem->data_slices[0]->d_col_indices,
          graph_slice->edges);
        util::CUBSelect<VertexId, SizeT>(
          problem->data_slices[0]->d_temp_storage,
          graph_slice->edges,
          problem->data_slices[0]->d_col_indices,
          num_selected);

        ////////////////////////////////////////////////////////////////////////
        // filter to remove all -1 in d_edge_weights
        util::MemsetCopyVectorKernel<<<128, 128>>>(
          problem->data_slices[0]->d_temp_storage,
          problem->data_slices[0]->d_edge_weights,
          graph_slice->edges);
        util::CUBSelect<VertexId, SizeT>(
          problem->data_slices[0]->d_temp_storage,
          graph_slice->edges,
          problem->data_slices[0]->d_edge_weights,
          num_selected);

        ////////////////////////////////////////////////////////////////////////
        // filter to remove all -1 in d_keys_array
        util::MemsetCopyVectorKernel<<<128, 128>>>(
          problem->data_slices[0]->d_temp_storage,
          problem->data_slices[0]->d_keys_array,
          graph_slice->edges);
        util::CUBSelect<VertexId, SizeT>(
          problem->data_slices[0]->d_temp_storage,
          graph_slice->edges,
          problem->data_slices[0]->d_keys_array,
          num_selected);

        ////////////////////////////////////////////////////////////////////////
        // filter to remove all -1 in d_origin_edges
        util::MemsetCopyVectorKernel<<<128, 128>>>(
          problem->data_slices[0]->d_temp_storage,
          problem->data_slices[0]->d_origin_edges,
          graph_slice->edges);
        util::CUBSelect<VertexId, SizeT>(
          problem->data_slices[0]->d_temp_storage,
          graph_slice->edges,
          problem->data_slices[0]->d_origin_edges,
          num_selected);

        if (DEBUG) printf("  * finished remove edges in one supervertex.\n");

        ////////////////////////////////////////////////////////////////////////
        // update edge list length in graph_slice [1]
        graph_slice->edges = *num_selected;

        if (DEBUG) printf("  * finished update #edge: %d\n",graph_slice->edges);

        if (debug_info)
        {
          printf(":: edge removal in one supervertex (d_keys_array) ::");
          util::DisplayDeviceResults(
            problem->data_slices[0]->d_keys_array, graph_slice->edges);
          printf(":: edge removal in one supervertex (d_col_indices) ::");
          util::DisplayDeviceResults(
            problem->data_slices[0]->d_col_indices, graph_slice->edges);
          printf(":: edge removal in one supervertex (d_edge_weights) ::");
          util::DisplayDeviceResults(
            problem->data_slices[0]->d_edge_weights, graph_slice->edges);
          printf(":: edge removal in one supervertex (d_origin_edges) ::");
          util::DisplayDeviceResults(
            problem->data_slices[0]->d_origin_edges, graph_slice->edges);
        }

        ////////////////////////////////////////////////////////////////////////
        // find supervertex ids for d_keys_array and d_col_indices
        frontier_attribute.queue_index  = 0;
        frontier_attribute.selector     = 0;
        frontier_attribute.queue_length = graph_slice->edges;
        frontier_attribute.queue_reset  = true;

        gunrock::oprtr::filter::Kernel
          <FilterKernelPolicy, MSTProblem, EdgeRmFunctor>
          <<<enactor_stats.filter_grid_size, FilterKernelPolicy::THREADS>>>(
            enactor_stats.iteration+1,
            frontier_attribute.queue_reset,
            frontier_attribute.queue_index,
            enactor_stats.num_gpus,
            frontier_attribute.queue_length,
            NULL,
            graph_slice->frontier_queues.d_values[frontier_attribute.selector],
            NULL,
            graph_slice->frontier_queues.d_values[frontier_attribute.selector^1],
            data_slice,
            NULL,
            work_progress,
            graph_slice->frontier_elements[frontier_attribute.selector],
            graph_slice->frontier_elements[frontier_attribute.selector^1],
            enactor_stats.filter_kernel_stats);

        if (DEBUG && (retval = util::GRError(cudaThreadSynchronize(),
          "filter::Kernel failed", __FILE__, __LINE__))) break;

        if (DEBUG) printf("  * finished find ids for keys and col_indices. \n");

        if (debug_info)
        {
          printf(":: keys_array found supervertex ids ::");
          util::DisplayDeviceResults(
            problem->data_slices[0]->d_keys_array, graph_slice->edges);
          printf(":: edgeId_list found supervertex ids ::");
          util::DisplayDeviceResults(
            problem->data_slices[0]->d_col_indices, graph_slice->edges);
        }

        ////////////////////////////////////////////////////////////////////////
        // bring edges, weights, origin_eids together according to keys
        util::MemsetCopyVectorKernel<<<128, 128>>>(
          problem->data_slices[0]->d_temp_storage,
          problem->data_slices[0]->d_keys_array,
          graph_slice->edges);

        util::MemsetCopyVectorKernel<<<128, 128>>>(
          problem->data_slices[0]->d_tmp_storage,
          problem->data_slices[0]->d_keys_array,
          graph_slice->edges);

        util::CUBRadixSort<VertexId, VertexId>(
          true,
          graph_slice->edges,
          problem->data_slices[0]->d_keys_array,
          problem->data_slices[0]->d_col_indices);

        util::CUBRadixSort<VertexId, Value>(
          true,
          graph_slice->edges,
          problem->data_slices[0]->d_temp_storage,
          problem->data_slices[0]->d_edge_weights);

        util::CUBRadixSort<VertexId, VertexId>(
          true,
          graph_slice->edges,
          problem->data_slices[0]->d_tmp_storage,
          problem->data_slices[0]->d_origin_edges);

        if (DEBUG) printf("  * finished sort according to new vertex ids.\n");
        ////////////////////////////////////////////////////////////////////////
        // remove duplicated edges between supervertices (optional operation)
        if (false)//(enactor_stats.iteration == 0)
        {
          //////////////////////////////////////////////////////////////////////
          // generate edge flag array based on src_vertice lst [1]
          // using MarkSegmentFromKeys on d_keys_array
          util::MemsetKernel<unsigned int><<<128, 128>>>(
            problem->data_slices[0]->d_flags_array, 0, graph_slice->edges);
          util::MarkSegmentFromKeys<<<128, 128>>>(
            problem->data_slices[0]->d_flags_array,
            problem->data_slices[0]->d_keys_array,
            graph_slice->edges);

          if (debug_info)
          {
            printf(":: mark segment to generate edge flag array [1] ::");
            util::DisplayDeviceResults(
              problem->data_slices[0]->d_flags_array, graph_slice->edges);
          }

          //////////////////////////////////////////////////////////////////////
          // generate edge flag array based on dst_vertice lst [2]
          // create a flags array on the ouput of segmented sort based on the
          // difference in uv pair using MarkSegmentsFromKeys kernel function
          util::MarkSegmentFromKeys<<<128, 128>>>(
            problem->data_slices[0]->d_edge_flags,
            problem->data_slices[0]->d_col_indices,
            graph_slice->edges);

          if (debug_info)
          {
            printf(":: mark segment to generate edge flag array [2] ::");
            util::DisplayDeviceResults(
              problem->data_slices[0]->d_edge_flags, graph_slice->edges);
          }

          //////////////////////////////////////////////////////////////////////
          // do or operation for d_edge_flags and d_flags_array - uv pair
          frontier_attribute.queue_index  = 0;
          frontier_attribute.selector     = 0;
          frontier_attribute.queue_length = graph_slice->edges;
          frontier_attribute.queue_reset  = true;

          gunrock::oprtr::filter::Kernel
            <FilterKernelPolicy, MSTProblem, OrFunctor>
            <<<enactor_stats.filter_grid_size, FilterKernelPolicy::THREADS>>>(
              enactor_stats.iteration+1,
              frontier_attribute.queue_reset,
              frontier_attribute.queue_index,
              enactor_stats.num_gpus,
              frontier_attribute.queue_length,
              NULL,
              graph_slice->frontier_queues.d_values[frontier_attribute.selector],
              NULL,
              graph_slice->frontier_queues.d_values[frontier_attribute.selector^1],
              data_slice,
              NULL,
              work_progress,
              graph_slice->frontier_elements[frontier_attribute.selector],
              graph_slice->frontier_elements[frontier_attribute.selector^1],
              enactor_stats.filter_kernel_stats);

          if (DEBUG && (retval = util::GRError(cudaThreadSynchronize(),
            "filter::Kernel failed", __FILE__, __LINE__))) break;

          if (DEBUG) printf("  * finished edge flags - second edge removal.\n");

          if (debug_info)
          {
            printf(":: duplicated edges between supervertices d_edge_flags ::");
            util::DisplayDeviceResults(
              problem->data_slices[0]->d_edge_flags, graph_slice->edges);
            printf(":: edge removal u lst (d_keys_array) ::");
            util::DisplayDeviceResults(
              problem->data_slices[0]->d_keys_array, graph_slice->edges);
            printf(":: edge removal v lst (d_col_indices) ::");
            util::DisplayDeviceResults(
              problem->data_slices[0]->d_col_indices, graph_slice->edges);
            printf(":: edge removal w lst (d_edge_weights) ::");
            util::DisplayDeviceResults(
              problem->data_slices[0]->d_edge_weights, graph_slice->edges);
          }

          //////////////////////////////////////////////////////////////////////
          // scan edge_flags to get edge_keys used for sorting
          Scan<MgpuScanTypeInc>(
          (int*)problem->data_slices[0]->d_edge_flags, graph_slice->edges,
          (int)0, mgpu::plus<int>(), (int*)0, (int*)0,
          (int*)problem->data_slices[0]->d_temp_storage, context);

          // set first bit of edge_flags back to 1
          util::MemsetKernel<unsigned int><<<1, 1>>>(
            problem->data_slices[0]->d_edge_flags, 1, 1);

          //////////////////////////////////////////////////////////////////////
          // calculate the number of segments for edge_offsets
          num_segments = Reduce(
            problem->data_slices[0]->d_edge_flags, graph_slice->edges, context);

          //////////////////////////////////////////////////////////////////////
          // generate edge_offsets used for SegSortFromIndices
          // edge_flags stored in d_row_offsets
          frontier_attribute.queue_index  = 0;
          frontier_attribute.selector     = 0;
          frontier_attribute.queue_length = graph_slice->edges;
          frontier_attribute.queue_reset  = true;

          gunrock::oprtr::filter::Kernel
            <FilterKernelPolicy, MSTProblem, EdgeOffsetsFunctor>
            <<<enactor_stats.filter_grid_size, FilterKernelPolicy::THREADS>>>(
              enactor_stats.iteration+1,
              frontier_attribute.queue_reset,
              frontier_attribute.queue_index,
              enactor_stats.num_gpus,
              frontier_attribute.queue_length,
              NULL,
              graph_slice->frontier_queues.d_values[frontier_attribute.selector],
              NULL,
              graph_slice->frontier_queues.d_values[frontier_attribute.selector^1],
              data_slice,
              NULL,
              work_progress,
              graph_slice->frontier_elements[frontier_attribute.selector],
              graph_slice->frontier_elements[frontier_attribute.selector^1],
              enactor_stats.filter_kernel_stats);

          if (DEBUG && (retval = util::GRError(cudaThreadSynchronize(),
            "filter::Kernel failed", __FILE__, __LINE__))) break;

          //////////////////////////////////////////////////////////////////////
          // segmented sort d_col_indices, d_edge_weights and d_origin_edges
          // copy d_edge_weights to d_temp_storage to use for segmented sort
          util::MemsetCopyVectorKernel<<<128, 128>>>(
            problem->data_slices[0]->d_temp_storage,
            problem->data_slices[0]->d_edge_weights,
            graph_slice->edges);

          util::SegSortFromIndices<SizeT, VertexId, Value>(
            context,
            num_segments,
            problem->data_slices[0]->d_row_offsets,
            graph_slice->edges,
            problem->data_slices[0]->d_edge_weights,
            problem->data_slices[0]->d_col_indices);

          util::SegSortFromIndices<SizeT, VertexId, VertexId>(
            context,
            num_segments,
            problem->data_slices[0]->d_row_offsets,
            graph_slice->edges,
            problem->data_slices[0]->d_temp_storage,
            problem->data_slices[0]->d_origin_edges);

          if (DEBUG) printf("  * finished segmentedSort for edge reduction.\n");

          if (debug_info)
          {
            printf(":: second reduction segmented sort d_col_indices ::");
            util::DisplayDeviceResults(
              problem->data_slices[0]->d_col_indices, graph_slice->edges);
            printf(":: second reduction segmented sort d_edge_weights ::");
            util::DisplayDeviceResults(
              problem->data_slices[0]->d_edge_weights, graph_slice->edges);
            printf(":: second reduction segmented sort d_origin_edges ::");
            util::DisplayDeviceResults(
              problem->data_slices[0]->d_origin_edges, graph_slice->edges);
          }

          //////////////////////////////////////////////////////////////////////
          // mark -1 to edges that needed to be removed using advance kernel
          frontier_attribute.queue_index  = 0;
          frontier_attribute.selector     = 0;
          frontier_attribute.queue_length = graph_slice->edges;
          frontier_attribute.queue_reset  = true;

          gunrock::oprtr::filter::Kernel
            <FilterKernelPolicy, MSTProblem, SuEdgeRmFunctor>
            <<<enactor_stats.filter_grid_size, FilterKernelPolicy::THREADS>>>(
              enactor_stats.iteration+1,
              frontier_attribute.queue_reset,
              frontier_attribute.queue_index,
              enactor_stats.num_gpus,
              frontier_attribute.queue_length,
              NULL,
              graph_slice->frontier_queues.d_values[frontier_attribute.selector],
              NULL,
              graph_slice->frontier_queues.d_values[frontier_attribute.selector^1],
              data_slice,
              NULL,
              work_progress,
              graph_slice->frontier_elements[frontier_attribute.selector],
              graph_slice->frontier_elements[frontier_attribute.selector^1],
              enactor_stats.filter_kernel_stats);

          if (DEBUG && (retval = util::GRError(cudaThreadSynchronize(),
            "filter::Kernel failed", __FILE__, __LINE__))) break;

          if (DEBUG) printf("  * finished mark -1 for duplicated edges.\n");

          //////////////////////////////////////////////////////////////////////
          // filter to remove all -1 in d_col_indices
          util::MemsetCopyVectorKernel<<<128, 128>>>(
            problem->data_slices[0]->d_temp_storage,
            problem->data_slices[0]->d_col_indices,
            graph_slice->edges);
          util::CUBSelect<VertexId, SizeT>(
            problem->data_slices[0]->d_temp_storage,
            graph_slice->edges,
            problem->data_slices[0]->d_col_indices,
            num_selected);

          //////////////////////////////////////////////////////////////////////
          // filter to remove all -1 in d_edge_weights
          util::MemsetCopyVectorKernel<<<128, 128>>>(
            problem->data_slices[0]->d_temp_storage,
            problem->data_slices[0]->d_edge_weights,
            graph_slice->edges);
          util::CUBSelect<VertexId, SizeT>(
            problem->data_slices[0]->d_temp_storage,
            graph_slice->edges,
            problem->data_slices[0]->d_edge_weights,
            num_selected);

          //////////////////////////////////////////////////////////////////////
          // filter to remove all -1 in d_keys_array
          util::MemsetCopyVectorKernel<<<128, 128>>>(
            problem->data_slices[0]->d_temp_storage,
            problem->data_slices[0]->d_keys_array,
            graph_slice->edges);
          util::CUBSelect<VertexId, SizeT>(
            problem->data_slices[0]->d_temp_storage,
            graph_slice->edges,
            problem->data_slices[0]->d_keys_array,
            num_selected);

          //////////////////////////////////////////////////////////////////////
          // filter to remove all -1 in d_origin_edges
          util::MemsetCopyVectorKernel<<<128, 128>>>(
            problem->data_slices[0]->d_temp_storage,
            problem->data_slices[0]->d_origin_edges,
            graph_slice->edges);
          util::CUBSelect<VertexId, SizeT>(
            problem->data_slices[0]->d_temp_storage,
            graph_slice->edges,
            problem->data_slices[0]->d_origin_edges,
            num_selected);

          if (DEBUG) printf("  * finished remove edges between supervertices.\n");

          graph_slice->edges = *num_selected;
          if (DEBUG) printf("  * finished update #edges: %d [2]\n", graph_slice->edges);

        } // end of removing duplicated edges between supervertices

        if (DEBUG) printf(" (d). Constructing the Vertex List.\n");

        ////////////////////////////////////////////////////////////////////////
        // flag array used for getting row_offsets for next iteration
        util::MarkSegmentFromKeys<<<128, 128>>>(
          problem->data_slices[0]->d_flags_array,
          problem->data_slices[0]->d_keys_array,
          graph_slice->edges);
        util::MemsetKernel<unsigned int><<<1, 1>>>(
          problem->data_slices[0]->d_flags_array, 1, 1);

        if (DEBUG) printf("  * finished scan of keys: flags for next iter.\n");

        ////////////////////////////////////////////////////////////////////////
        // generate row_offsets for next iteration
        frontier_attribute.queue_index  = 0;
        frontier_attribute.selector     = 0;
        frontier_attribute.queue_length = graph_slice->edges;
        frontier_attribute.queue_reset  = true;

        gunrock::oprtr::filter::Kernel
          <FilterKernelPolicy, MSTProblem, RowOffsetsFunctor>
          <<<enactor_stats.filter_grid_size, FilterKernelPolicy::THREADS>>>(
            enactor_stats.iteration+1,
            frontier_attribute.queue_reset,
            frontier_attribute.queue_index,
            enactor_stats.num_gpus,
            frontier_attribute.queue_length,
            NULL,
            graph_slice->frontier_queues.d_values[frontier_attribute.selector],
            NULL,
            graph_slice->frontier_queues.d_values[frontier_attribute.selector^1],
            data_slice,
            NULL,
            work_progress,
            graph_slice->frontier_elements[frontier_attribute.selector],
            graph_slice->frontier_elements[frontier_attribute.selector^1],
            enactor_stats.filter_kernel_stats);

        if (DEBUG && (retval = util::GRError(cudaThreadSynchronize(),
          "filter::Kernel failed", __FILE__, __LINE__))) break;

        ////////////////////////////////////////////////////////////////////////
        // copy back d_col_indices back to column indices in graph_slice
        util::MemsetCopyVectorKernel<<<128, 128>>>(
          graph_slice->d_column_indices,
          problem->data_slices[0]->d_col_indices,
          graph_slice->edges);

        ////////////////////////////////////////////////////////////////////////
        // set last element of row_offsets manually & copy back to graph_slice
        util::MemsetKernel<<<128, 128>>>(
          problem->data_slices[0]->d_row_offsets + graph_slice->nodes,
          graph_slice->edges, 1);
        util::MemsetCopyVectorKernel<<<128, 128>>>(
          graph_slice->d_row_offsets,
          problem->data_slices[0]->d_row_offsets,
          graph_slice->nodes + 1);

        if (DEBUG) printf("  * finished calculate row_offset for next iter.\n");

        if (debug_info)
        {
          printf(":: final graph_slice d_column_indices ::");
          util::DisplayDeviceResults(
            graph_slice->d_column_indices, graph_slice->edges);
          printf(":: final keys for current iteration ::");
          util::DisplayDeviceResults(
            problem->data_slices[0]->d_keys_array, graph_slice->edges);
          printf(":: final edge_values for current iteration ::");
          util::DisplayDeviceResults(
            problem->data_slices[0]->d_edge_weights, graph_slice->edges);
          printf(":: final d_origin_edges for current iteration ::");
          util::DisplayDeviceResults(
            problem->data_slices[0]->d_origin_edges, graph_slice->edges);
        }

        printf("END OF ITERATION:%lld #NODES LEFT: %d #EDGES LEFT: %d\n",
          enactor_stats.iteration+1, graph_slice->nodes, graph_slice->edges);

        /*
          // number of selected edges current iteration
          tmp_select = tmp_length;
          tmp_length = Reduce(
            problem->data_slices[0]->d_mst_output, num_edges_origin, context);
          printf(" #Selected edges current iteration:%d\n",
            (tmp_length - tmp_select));
        */

        enactor_stats.iteration++;
        loop_limit++; // debug
        if (loop_limit >= 100) break; // debug

      } // end of the mst recursive loop

      delete num_selected;
      if (retval) break;

      //////////////////////////////////////////////////////////////////////////
      // Check if any of the frontiers overflowed due to redundant expansion
      bool overflowed = false;
      if (retval = work_progress.CheckOverflow<SizeT>(overflowed)) break;
      if (overflowed)
      {
        retval = util::GRError(cudaErrorInvalidConfiguration,
          "Frontier queue overflow. Please increase queue-sizing factor.",
          __FILE__, __LINE__); break;
      }

    }while(0);
    if (DEBUG)
      printf("\n GPU Minimum Spanning Tree Computation Enactor Complete. \n");
    return retval;
  }

  /**
   * @brief MST Enact kernel entry.
   *
   * @tparam MSTProblem MST Problem type. @see MSTProblem
   *
   * @param[in] context CudaContext for moderngpu library
   * @param[in] problem Pointer to MSTProblem object.
   * @param[in] max_grid_size Max grid size for MST kernel calls.
   *
   * \return cudaError_t object which indicates the success of
   * all CUDA function calls.
   */
  template <typename MSTProblem>
  cudaError_t Enact(
    CudaContext &context,
    MSTProblem  *problem,
    int         max_grid_size = 0)
  {
    if (this->cuda_props.device_sm_version >= 300)
    {
      typedef gunrock::oprtr::filter::KernelPolicy<
        MSTProblem,         // Problem data type
        300,                // CUDA_ARCH
        INSTRUMENT,         // INSTRUMENT
        0,                  // SATURATION QUIT
        true,               // DEQUEUE_PROBLEM_SIZE
        8,                  // MIN_CTA_OCCUPANCY
        8,                  // LOG_THREADS
        1,                  // LOG_LOAD_VEC_SIZE
        0,                  // LOG_LOADS_PER_TILE
        5,                  // LOG_RAKING_THREADS
        5,                  // END_BITMASK_CULL
        8>                  // LOG_SCHEDULE_GRANULARITY
        FilterKernelPolicy;

      typedef gunrock::oprtr::advance::KernelPolicy<
        MSTProblem,         // Problem data type
        300,                // CUDA_ARCH
        INSTRUMENT,         // INSTRUMENT
        8,                  // MIN_CTA_OCCUPANCY
        10,                 // LOG_THREADS
        8,                  // LOG_BLOCKS
        32 * 128,           // LIGHT_EDGE_THRESHOLD
        1,                  // LOG_LOAD_VEC_SIZE
        0,                  // LOG_LOADS_PER_TILE
        5,                  // LOG_RAKING_THREADS
        32,                 // WARP_GATHER_THRESHOLD
        128 * 4,            // CTA_GATHER_THRESHOLD
        7,                  // LOG_SCHEDULE_GRANULARITY
        gunrock::oprtr::advance::LB>
        AdvanceKernelPolicy;

      return EnactMST<
        AdvanceKernelPolicy,
        FilterKernelPolicy,
        MSTProblem>(context, problem, max_grid_size);
    }

    //to reduce compile time, get rid of other architecture for now
    //TODO: add all the kernel policy settings for all archs

    printf("Not yet tuned for this architecture\n");
    return cudaErrorInvalidDeviceFunction;
  }

  /**
   * \addtogroup PublicInterface
   * @{
   */

  /** @} */

};

} // namespace mst
} // namespace app
} // namespace gunrock

// Leave this at the end of the file
// Local Variables:
// mode:c++
// c-file-style: "NVIDIA"
// End: