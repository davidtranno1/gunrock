// ----------------------------------------------------------------
// Gunrock -- Fast and Efficient GPU Graph Library
// ----------------------------------------------------------------
// This source code is distributed under the terms of LICENSE.TXT
// in the root directory of this source distribution.
// ----------------------------------------------------------------

/**
 * @file
 * bfs_problem.cuh
 *
 * @brief GPU Storage management Structure for BFS Problem Data
 */

#pragma once

#include <gunrock/app/problem_base.cuh>
#include <gunrock/util/memset_kernel.cuh>
#include <gunrock/util/array_utils.cuh>

namespace gunrock {
namespace app {
namespace bfs {

/**
 * @brief Breadth-First Search Problem structure stores device-side vectors for doing BFS computing on the GPU.
 *
 * @tparam VertexId             Type of signed integer to use as vertex id (e.g., uint32)
 * @tparam SizeT                Type of unsigned integer to use for array indexing. (e.g., uint32)
 * @tparam Value                Type of float or double to use for computing BC value.
 * @tparam _MARK_PREDECESSORS   Boolean type parameter which defines whether to mark predecessor value for each node.
 * @tparam _ENABLE_IDEMPOTENCE  Boolean type parameter which defines whether to enable idempotence operation for graph traverse.
 * @tparam _USE_DOUBLE_BUFFER   Boolean type parameter which defines whether to use double buffer.
 */
template <
    typename    VertexId,                       
    typename    SizeT,                          
    typename    Value,                          
    bool        _MARK_PREDECESSORS,             
    bool        _ENABLE_IDEMPOTENCE,
    bool        _USE_DOUBLE_BUFFER>
struct BFSProblem : ProblemBase<VertexId, SizeT, Value,
    _MARK_PREDECESSORS, 
    _ENABLE_IDEMPOTENCE, 
    _USE_DOUBLE_BUFFER, 
    false, // _ENABLE_BACKWARD
    false, // _KEEP_ORDER
    false> // _KEEP_NODE_NUM
{
    //Helper structures

    typedef ProblemBase<VertexId, SizeT, Value, _MARK_PREDECESSORS,
        _ENABLE_IDEMPOTENCE, _USE_DOUBLE_BUFFER, false, false, false>
        BaseProblem;
    /**
     * @brief Data slice structure which contains BFS problem specific data.
     */
    struct DataSlice : DataSliceBase<VertexId, SizeT, Value>
    {
        util::Array1D<SizeT, VertexId      > labels        ;   
        util::Array1D<SizeT, unsigned char > visited_mask  ;
        util::Array1D<SizeT, unsigned int  > temp_marker   ;

        DataSlice()
        {   
            labels          .SetName("labels"          );  
            visited_mask    .SetName("visited_mask"    );
            temp_marker     .SetName("temp_marker"     );
        }

        ~DataSlice()
        {
            if (util::SetDevice(this->gpu_idx)) return;
            labels        .Release();
            visited_mask  .Release();
            temp_marker   .Release();
        }

        cudaError_t Init(
            int   num_gpus,
            int   gpu_idx,
            Csr<VertexId, Value, SizeT> *graph)
        {
            cudaError_t retval = cudaSuccess;
            if (retval = DataSliceBase<SizeT, VertexId, Value>::Init(
                gpu_idx, graph)) return retval;

            // Create SoA on device
            if (retval = labels       .Allocate(graph->nodes,util::DEVICE)) return retval;

            if (_MARK_PREDECESSORS)
            {
                if (retval = this->preds     .Allocate(graph->nodes,util::DEVICE)) return retval;
                if (retval = this->temp_preds.Allocate(graph->nodes,util::DEVICE)) return retval;
            }

            if (_ENABLE_IDEMPOTENCE) 
            {
                if (retval = visited_mask.Allocate((graph->nodes +7)/8, util::DEVICE)) return retval;
            } 

            /*if (num_gpus > 1)
            {
                this->vertex_associate_orgs[0] = labels.GetPointer(util::DEVICE);
                if (_MARK_PREDECESSORS)
                    this->vertex_associate_orgs[1] = this->preds.GetPointer(util::DEVICE);
                if (retval = this->vertex_associate_orgs.Move(util::HOST, util::DEVICE)) return retval;
                if (retval = temp_marker. Allocate(graph->nodes, util::DEVICE)) return retval;
            }*/
            return retval;
        } // end Init

        cudaError_t Reset(
            //FrontierType frontier_type,     // The frontier type (i.e., edge/vertex/mixed)
            GraphSlice<VertexId, SizeT, Value>  *graph_slice)
        {         
            cudaError_t retval = cudaSuccess;
            SizeT nodes = graph_slice->nodes;
            SizeT edges = graph_slice->edges;
            
            // TODO: put in bfs_enactor reset
            /*for (int peer=0; peer<this->num_gpus; peer++)
                this->out_length[peer] = 1;
 
            if (this->num_gpus>1) 
                util::cpu_mt::PrintCPUArray<int, SizeT>("in_counter", graph_slice->in_counter.GetPointer(util::HOST), this->num_gpus+1, this->gpu_idx); 
            */

            // Allocate output labels if necessary
            if (retval = this->labels.Allocate(nodes,util::DEVICE)) 
                return retval;
            util::MemsetKernel<<<128, 128>>>(
                this->labels.GetPointer(util::DEVICE), 
                _ENABLE_IDEMPOTENCE ? -1 : (util::MaxValue<Value>()-1), nodes);

            // Allocate preds if necessary
            if (_MARK_PREDECESSORS && !_ENABLE_IDEMPOTENCE)
            {
                if (retval = this->preds.Allocate(nodes, util::DEVICE)) 
                    return retval;
                util::MemsetKernel<<<128,128>>>(
                    this->preds.GetPointer(util::DEVICE), -2, nodes); 
            }

            if (_ENABLE_IDEMPOTENCE) {
                SizeT visited_mask_bytes 
                    = ((nodes * sizeof(unsigned char))+7)/8;
                SizeT visited_mask_elements 
                    = visited_mask_bytes * sizeof(unsigned char);
                util::MemsetKernel<<<128, 128>>>(
                    this->visited_mask.GetPointer(util::DEVICE), 
                    (unsigned char)0, visited_mask_elements);
            }
            
            return retval;
        } 
    }; // DataSlice

    // Members
    util::Array1D<SizeT, DataSlice> *data_slices;
    
    // Methods

    /**
     * @brief BFSProblem default constructor
     */
    BFSProblem()
    {
        data_slices = NULL;
    }

    /**
     * @brief BFSProblem default destructor
     */
    ~BFSProblem()
    {
        if (data_slices==NULL) return;
        for (int i = 0; i < this->num_gpus; ++i)
        {
            util::SetDevice(this->gpu_idx[i]);
            data_slices[i].Release();
        }
        delete[] data_slices;data_slices=NULL;
    }

    /**
     * \addtogroup PublicInterface
     * @{
     */

    /**
     * @brief Copy result labels and/or predecessors computed on the GPU back to host-side vectors.
     *
     * @param[out] h_labels host-side vector to store computed node labels (distances from the source).
     * @param[out] h_preds host-side vector to store predecessor vertex ids.
     *
     *\return cudaError_t object which indicates the success of all CUDA function calls.
     */
    cudaError_t Extract(VertexId *h_labels, VertexId *h_preds)
    {
        cudaError_t retval = cudaSuccess;
 
        do {
            if (this->num_gpus == 1) {

                // Set device
                if (retval = util::SetDevice(this->gpu_idx[0])) return retval;

                data_slices[0]->labels.SetPointer(h_labels);
                if (retval = data_slices[0]->labels.Move(util::DEVICE,util::HOST)) return retval;

                if (_MARK_PREDECESSORS) {
                    data_slices[0]->preds.SetPointer(h_preds);
                    if (retval = data_slices[0]->preds.Move(util::DEVICE,util::HOST)) return retval;
                }

            } else {
                VertexId **th_labels=new VertexId*[this->num_gpus];
                VertexId **th_preds =new VertexId*[this->num_gpus];
                for (int gpu=0;gpu<this->num_gpus;gpu++)
                {
                    if (retval = util::SetDevice(this->gpu_idx[gpu])) return retval;
                    if (retval = data_slices[gpu]->labels.Move(util::DEVICE,util::HOST)) return retval;
                    th_labels[gpu]=data_slices[gpu]->labels.GetPointer(util::HOST);
                    if (_MARK_PREDECESSORS) {
                        if (retval = data_slices[gpu]->preds.Move(util::DEVICE,util::HOST)) return retval;
                        th_preds[gpu]=data_slices[gpu]->preds.GetPointer(util::HOST);
                    }
                } //end for(gpu)
                
                for (VertexId node=0;node<this->nodes;node++)
                if (this-> partition_tables[0][node]>=0 && this-> partition_tables[0][node]<this->num_gpus &&
                    this->convertion_tables[0][node]>=0 && this->convertion_tables[0][node]<data_slices[this->partition_tables[0][node]]->labels.GetSize())
                    h_labels[node]=th_labels[this->partition_tables[0][node]][this->convertion_tables[0][node]];
                else {
                    printf("OutOfBound: node = %d, partition = %d, convertion = %d\n",
                           node, this->partition_tables[0][node], this->convertion_tables[0][node]); 
                    fflush(stdout);
                }
                if (_MARK_PREDECESSORS)
                    for (VertexId node=0;node<this->nodes;node++)
                        h_preds[node]=th_preds[this->partition_tables[0][node]][this->convertion_tables[0][node]];
                for (int gpu=0;gpu<this->num_gpus;gpu++)
                {
                    if (retval = data_slices[gpu]->labels.Release(util::HOST)) return retval;
                    if (retval = data_slices[gpu]->preds.Release(util::HOST)) return retval;
                }
                delete[] th_labels;th_labels=NULL;
                delete[] th_preds ;th_preds =NULL;
            } //end if (data_slices.size() ==1)
        } while(0);

        return retval;
    }

    /**
     * @brief BFSProblem initialization
     *
     * @param[in] stream_from_host Whether to stream data from host.
     * @param[in] graph Reference to the CSR graph object we process on. @see Csr
     * @param[in] _num_gpus Number of the GPUs used.
     *
     * \return cudaError_t object which indicates the success of all CUDA function calls.
     */
    cudaError_t Init(
            bool        stream_from_host,       // Only meaningful for single-GPU
            Csr<VertexId, Value, SizeT> *graph,
            Csr<VertexId, Value, SizeT> *inversgraph = NULL,
            int         num_gpus         = 1,
            int*        gpu_idx          = NULL,
            std::string partition_method ="random",
            float       partition_factor = -1.0f,
            int         partition_seed   = -1)
    {
        cudaError_t retval = cudaSuccess;

        if (retval = BaseProblem::Init(
            stream_from_host,
            graph,
            inversgraph,
            num_gpus,
            gpu_idx,
            partition_method,
            partition_factor,
            partition_seed)) return retval;

        // No data in DataSlice needs to be copied from host

        data_slices = new util::Array1D<SizeT,DataSlice>[this->num_gpus];

        do {
            for (int gpu=0;gpu<this->num_gpus;gpu++)
            {
                data_slices[gpu].SetName("data_slices[]");
                if (retval = util::GRError(cudaSetDevice(this->gpu_idx[gpu]), "BFSProblem cudaSetDevice failed", __FILE__, __LINE__)) return retval;
                if (retval = data_slices[gpu].Allocate(1,util::DEVICE | util::HOST)) return retval;
                DataSlice* _data_slice = data_slices[gpu].GetPointer(util::HOST);
                if (retval = _data_slice->Init(
                        this->num_gpus,
                        this->gpu_idx[gpu], 
                        &(this->sub_graphs[gpu])
                        //this->num_gpus > 1? this->graph_slices[gpu]->in_counter.GetPointer(util::HOST) : NULL,
                        //this->num_gpus > 1? this->graph_slices[gpu]->out_counter.GetPointer(util::HOST): NULL,
                        //this->num_gpus > 1? this->graph_slices[gpu]->original_vertex.GetPointer(util::HOST) : NULL,
                        )) return retval;

                if (this->ENABLE_IDEMPOTENCE) {
                    SizeT bytes = (this->graph_slices[gpu]->nodes + 8 - 1) / 8;
                    cudaChannelFormatDesc   bitmask_desc = cudaCreateChannelDesc<char>();
                    gunrock::oprtr::filter::BitmaskTex<unsigned char>::ref.channelDesc = bitmask_desc;
                    if (retval = util::GRError(cudaBindTexture(
                        0,  
                        gunrock::oprtr::filter::BitmaskTex<unsigned char>::ref,
                        data_slices[gpu]->visited_mask.GetPointer(util::DEVICE),
                        bytes),
                    "BFSEnactor cudaBindTexture bitmask_tex_ref failed", __FILE__, __LINE__)) return retval;
                }   
            } //end for(gpu)
        } while (0);
        
        return retval;
    }

    /**
     *  @brief Performs any initialization work needed for BFS problem type. Must be called prior to each BFS run.
     *
     *  @param[in] src Source node for one BFS computing pass.
     *  @param[in] frontier_type The frontier type (i.e., edge/vertex/mixed)
     *  @param[in] queue_sizing Size scaling factor for work queue allocation (e.g., 1.0 creates n-element and m-element vertex and edge frontiers, respectively).
     * 
     *  \return cudaError_t object which indicates the success of all CUDA function calls.
     */
    cudaError_t Reset()
    {
        cudaError_t retval = cudaSuccess;

        for (int gpu = 0; gpu < this->num_gpus; ++gpu) {
            // Set device
            if (retval = util::SetDevice(this->gpu_idx[gpu])) return retval;
            if (retval = data_slices[gpu]->Reset(this->graph_slices[gpu])) return retval;
            if (retval = data_slices[gpu].Move(util::HOST, util::DEVICE)) return retval;
        }
 
       return retval;
    } // reset

    /** @} */

}; // bfs_problem

} //namespace bfs
} //namespace app
} //namespace gunrock

// Leave this at the end of the file
// Local Variables:
// mode:c++
// c-file-style: "NVIDIA"
// End:
