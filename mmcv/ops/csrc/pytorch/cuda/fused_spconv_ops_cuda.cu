#include <cuda_runtime_api.h>
#include <spconv/spconv/indice.h>
#include <spconv/spconv/reordering.h>
#include <spconv/torch_utils.h>
#include <torch/script.h>

#include "pytorch_cuda_helper.hpp"

template <typename scalar_t>
torch::Tensor FusedIndiceConvBatchnormCUDAKernelLauncher(
    torch::Tensor features, torch::Tensor filters, torch::Tensor bias,
    torch::Tensor indicePairs, torch::Tensor indiceNum, int64_t numActOut,
    int64_t _inverse, int64_t _subM) {
  bool subM = _subM != 0;
  bool inverse = _inverse != 0;
  auto device = features.device().type();
  auto ndim = filters.dim() - 2;
  auto kernelVolume = indicePairs.size(0);
  auto numInPlanes = features.size(1);
  auto numOutPlanes = filters.size(ndim + 1);
  auto indicePairNumCpu = indiceNum.to({torch::kCPU});
  auto indicePairMaxSizeIter =
      std::max_element(indicePairNumCpu.data_ptr<int>(),
                       indicePairNumCpu.data_ptr<int>() + kernelVolume);
  int indicePairMaxOffset =
      indicePairMaxSizeIter - indicePairNumCpu.data_ptr<int>();
  int indicePairMaxSize = *indicePairMaxSizeIter;

  auto options =
      torch::TensorOptions().dtype(features.dtype()).device(features.device());

  torch::Tensor output =
      torch::zeros({numActOut, numOutPlanes}, options).copy_(bias);
  torch::Tensor inputBuffer =
      torch::zeros({indicePairMaxSize, numInPlanes}, options);
  torch::Tensor outputBuffer =
      torch::zeros({indicePairMaxSize, numOutPlanes}, options);
  filters = filters.view({-1, numInPlanes, numOutPlanes});
  if (subM) {  // the center index of subm conv don't need gather and scatter
               // add.
    torch::mm_out(output, features, filters[indicePairMaxOffset]);
  }
  double totalGatherTime = 0;
  double totalGEMMTime = 0;
  double totalSAddTime = 0;
  for (int i = 0; i < kernelVolume; ++i) {
    auto nHot = indicePairNumCpu.data_ptr<int>()[i];
    if (nHot <= 0 || (subM && i == indicePairMaxOffset)) {
      continue;
    }
    auto outputBufferBlob = torch::from_blob(outputBuffer.data_ptr<scalar_t>(),
                                             {nHot, numOutPlanes}, options);
    auto inputBufferBlob = torch::from_blob(inputBuffer.data_ptr<scalar_t>(),
                                            {nHot, numInPlanes}, options);

    if (device == torch::kCPU) {
      functor::SparseGatherFunctor<tv::CPU, scalar_t, int> gatherFtor;
      gatherFtor(tv::CPU(), tv::torch2tv<scalar_t>(inputBuffer),
                 tv::torch2tv<const scalar_t>(features),
                 tv::torch2tv<const int>(indicePairs).subview(i, inverse),
                 nHot);
    } else {
      functor::SparseGatherFunctor<tv::GPU, scalar_t, int> gatherFtor;
      gatherFtor(tv::TorchGPU(), tv::torch2tv<scalar_t>(inputBuffer),
                 tv::torch2tv<const scalar_t>(features),
                 tv::torch2tv<const int>(indicePairs).subview(i, inverse),
                 nHot);
      TV_CHECK_CUDA_ERR();
      /* slower than SparseGatherFunctor, may due to int->long conversion
      auto indicePairLong = indicePairs[i][inverse].to(torch::kInt64);
      auto indicePairBlob = torch::from_blob(indicePairLong.data_ptr<long>(),
      {nHot}, indicePairOptions); torch::index_select_out(inputBufferBlob,
      features, 0, indicePairBlob);*/
    }
    torch::mm_out(outputBufferBlob, inputBufferBlob, filters[i]);

    if (device == torch::kCPU) {
      functor::SparseScatterAddFunctor<tv::CPU, scalar_t, int> scatterFtor;
      scatterFtor(tv::CPU(), tv::torch2tv<scalar_t>(output),
                  tv::torch2tv<const scalar_t>(outputBuffer),
                  tv::torch2tv<const int>(indicePairs).subview(i, !inverse),
                  nHot, true);
    } else {
      functor::SparseScatterAddFunctor<tv::GPU, scalar_t, int> scatterFtor;
      scatterFtor(tv::TorchGPU(), tv::torch2tv<scalar_t>(output),
                  tv::torch2tv<const scalar_t>(outputBuffer),
                  tv::torch2tv<const int>(indicePairs).subview(i, !inverse),
                  nHot, true);
      TV_CHECK_CUDA_ERR();
    }
  }

  return output;
}

template torch::Tensor FusedIndiceConvBatchnormCUDAKernelLauncher<float>(
    torch::Tensor features, torch::Tensor filters, torch::Tensor bias,
    torch::Tensor indicePairs, torch::Tensor indiceNum, int64_t numActOut,
    int64_t _inverse, int64_t _subM);

template torch::Tensor FusedIndiceConvBatchnormCUDAKernelLauncher<at::Half>(
    torch::Tensor features, torch::Tensor filters, torch::Tensor bias,
    torch::Tensor indicePairs, torch::Tensor indiceNum, int64_t numActOut,
    int64_t _inverse, int64_t _subM);
