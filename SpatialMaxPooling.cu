#include <THC/THC.h>
#define CUDA_MAX_THREADS 1024   // this is safe, in reality 256 is our limit

extern "C"
{
void SpatialMaxPooling_updateOutput(THCState* state, THCudaTensor* input,
    THCudaTensor* output, THCudaTensor* indices, int kW, int kH, int dW, int dH);
void SpatialMaxPooling_updateGradInput(THCState* state, THCudaTensor* input,
    THCudaTensor* gradInput, THCudaTensor* gradOutput, THCudaTensor* indices, int kW, int kH, int dW, int dH);
}



/*
 * Description:
 *    this function maxpools an input 4D tensor along dimensions 2 and 3
 *    4D input, 4D output, 4D argmax x and y 
 */
__global__ void maxpool(float *input, float *output, float *indices_x, float *indices_y,
                        int input_n, int input_h, int input_w,
                        int kH, int kW, int dH, int dW)
{
  // iterators
  int xx, yy;

  // output size
  const int output_w = ceil(float(input_w - kW) / float(dW) + 1);
  const int output_h = ceil(float(input_h - kH) / float(dH) + 1);

  // compute offsets based on thread/block ID
  int o = blockIdx.x;
  int i = o;
  //int k = blockIdx.x % input_n;

  int xx_start = threadIdx.x;
  int xx_end = output_w;
  const int xx_step = blockDim.x;

  int yy_start = blockDim.y*blockIdx.y + threadIdx.y;
  int yy_end = output_h;
  const int yy_step = blockDim.y*gridDim.y;

  // select input/output plane
  output = output + o*output_w*output_h;
  input = input + i*input_w*input_h;
  indices_x = indices_x + o*output_w*output_h;
  indices_y = indices_y + o*output_w*output_h;

  // For all output pixels...
  for(yy = yy_start; yy < yy_end; yy+=yy_step) {
    for(xx = xx_start; xx < xx_end; xx+=xx_step) {
      // Compute the mean of the input image...
      float *ptr_input = input + yy*dH*input_w + xx*dW;
      float *ptr_output = output + yy*output_w + xx;
      float *ptr_ind_x = indices_x + yy*output_w + xx;
      float *ptr_ind_y = indices_y + yy*output_w + xx;
      int argmax_x = -1;
      int argmax_y = -1;
      float max = -FLT_MAX;
      int kx, ky;
      for(ky = 0; ky < kH; ky++) {
        for(kx = 0; kx < kW; kx++) {
          if((xx*dW+kx < input_w) & (yy*dH+ky < input_h)) {
            float val = ptr_input[kx];
            if (val > max) {
              max = val;
              argmax_x = kx;
              argmax_y = ky;
            }
          }
        }
        ptr_input += input_w; // next input line
      }
      // Update output and argmax
      *ptr_output = max;
      *ptr_ind_x = argmax_x + 1;
      *ptr_ind_y = argmax_y + 1;
    }
  }
}

/*
 * Description:
 *    this function computes the gradInput from weight and gradOutput
 */
__global__ void maxgradinput(float *gradInput, float *gradOutput, float *indices_x, float *indices_y,
                             int input_n, int input_h, int input_w,
                             int kH, int kW, int dH, int dW)
{
  // iterators
  int xx, yy;

  // output size
  int output_w = ceil(float(input_w - kW) / float(dW) + 1);
  int output_h = ceil(float(input_h - kH) / float(dH) + 1);

  // compute offsets based on thread/block ID
  int o = blockIdx.x;
  int i = o;
  //int k = blockIdx.x % input_n;

  int xx_start = threadIdx.x;
  int xx_end = output_w;
  int xx_step = blockDim.x;

  int yy_start = blockDim.y*blockIdx.y + threadIdx.y;
  int yy_end = output_h;
  int yy_step = blockDim.y*gridDim.y;

  // select input/output plane
  gradOutput = gradOutput + o*output_w*output_h;
  gradInput = gradInput + i*input_w*input_h;
  indices_x = indices_x + o*output_w*output_h;
  indices_y = indices_y + o*output_w*output_h;

  // compute gradInput
  for(yy = yy_start; yy < yy_end; yy+=yy_step) {
    for(xx = xx_start; xx < xx_end; xx+=xx_step) {
      float *ptr_gradInput = gradInput + yy*dH*input_w + xx*dW;
      float *ptr_gradOutput = gradOutput + yy*output_w + xx;
      float *ptr_ind_x = indices_x + yy*output_w + xx;
      float *ptr_ind_y = indices_y + yy*output_w + xx;
      float z = *ptr_gradOutput;

      int argmax_x = (*ptr_ind_x)-1;
      int argmax_y = (*ptr_ind_y)-1;

      ptr_gradInput[argmax_x + argmax_y*input_w] += z;
    }
  }
}

/*
 * Description:
 *    this function computes the gradInput from weight and gradOutput
 *    when kH != dH or kW != dW (uses atomic add)
 */
__global__ void atomicmaxgradinput(
  float *gradInput, float *gradOutput, float *indices_x, float *indices_y,
  int input_n, int input_h, int input_w, int kH, int kW, int dH, int dW
)
{
  // iterators
  int xx, yy;

  // output size
  int output_w = ceil(float(input_w - kW) / float(dW) + 1);
  int output_h = ceil(float(input_h - kH) / float(dH) + 1);

  // compute offsets based on thread/block ID
  int o = blockIdx.x;
  int i = o;
  //int k = blockIdx.x % input_n;

  int xx_start = threadIdx.x;
  int xx_end = output_w;
  int xx_step = blockDim.x;

  int yy_start = blockDim.y*blockIdx.y + threadIdx.y;
  int yy_end = output_h;
  int yy_step = blockDim.y*gridDim.y;

  // select input/output plane
  gradOutput = gradOutput + o*output_w*output_h;
  gradInput = gradInput + i*input_w*input_h;
  indices_x = indices_x + o*output_w*output_h;
  indices_y = indices_y + o*output_w*output_h;

  // compute gradInput
  for(yy = yy_start; yy < yy_end; yy+=yy_step) {
    for(xx = xx_start; xx < xx_end; xx+=xx_step) {
      float *ptr_gradInput = gradInput + yy*dH*input_w + xx*dW;
      float *ptr_gradOutput = gradOutput + yy*output_w + xx;
      float *ptr_ind_x = indices_x + yy*output_w + xx;
      float *ptr_ind_y = indices_y + yy*output_w + xx;
      float z = *ptr_gradOutput;

      int argmax_x = (*ptr_ind_x)-1;
      int argmax_y = (*ptr_ind_y)-1;

      // atomic add since different threads could update same variable
      atomicAdd(&(ptr_gradInput[argmax_x + argmax_y*input_w]), z);
    }
  }
}

void SpatialMaxPooling_updateOutput(THCState* state, THCudaTensor* input, 
    THCudaTensor* output, THCudaTensor* indices, int kW, int kH, int dW, int dH)
{
  float *indices_data;
  float *output_data;
  float *input_data;

  //luaL_argcheck(L, input->nDimension == 3 || input->nDimension == 4, 2, "3D or 4D (batch) tensor expected");

  if (input->nDimension == 3) {
    long nInputCols = input->size[2];
    long nInputRows = input->size[1];
    long nInputPlane = input->size[0];
    long nOutputCols = ceil(float(nInputCols - kW) / float(dW) + 1);
    long nOutputRows = ceil(float(nInputRows - kH) / float(dH) + 1);

    //luaL_argcheck(L, nInputCols >= kW && nInputRows >= kH, 2, "input image smaller than kernel size");

    input = THCudaTensor_newContiguous(state, input);
    input_data = THCudaTensor_data(state, input);

    THCudaTensor_resize3d(state, output, nInputPlane, nOutputRows, nOutputCols);
    THCudaTensor_resize4d(state, indices, 2, nInputPlane, nOutputRows, nOutputCols);
    
    indices_data = THCudaTensor_data(state, indices);
    output_data = THCudaTensor_data(state, output);

    // cuda blocks & threads:
    int yblocks = (int)(16L / nInputPlane);
    yblocks = yblocks < 1 ? 1 : yblocks;
    dim3 blocks(nInputPlane,yblocks);
    dim3 threads(32,8);

    // run maxpool kernel
    maxpool <<<blocks, threads>>> (input_data, output_data, 
                                   indices_data+nInputPlane*nOutputCols*nOutputRows, indices_data,
                                   nInputPlane, nInputRows, nInputCols, kH, kW, dH, dW);
  } else {
    long nInputCols = input->size[3];
    long nInputRows = input->size[2];
    long nInputPlane = input->size[1];
    long nbatch = input->size[0];
    long nOutputCols = ceil(float(nInputCols - kW) / float(dW) + 1);
    long nOutputRows = ceil(float(nInputRows - kH) / float(dH) + 1);

    //luaL_argcheck(L, nInputCols >= kW && nInputRows >= kH, 2, "input image smaller than kernel size");

    input = THCudaTensor_newContiguous(state, input);
    input_data = THCudaTensor_data(state, input);

    THCudaTensor_resize4d(state, output, nbatch, nInputPlane, nOutputRows, nOutputCols);
    THCudaTensor_resize5d(state, indices, 2, nbatch, nInputPlane, nOutputRows, nOutputCols);

    indices_data = THCudaTensor_data(state, indices);
    output_data = THCudaTensor_data(state, output);

    // cuda blocks & threads:
    int yblocks = (int)(16L / nInputPlane);
    yblocks = yblocks < 1 ? 1 : yblocks;
    dim3 blocks(nInputPlane*nbatch,yblocks);
    dim3 threads(32,8);

    // run maxpool kernel
    maxpool <<<blocks, threads>>> (input_data, output_data,
                                   indices_data+nbatch*nInputPlane*nOutputCols*nOutputRows, indices_data,
                                   nInputPlane, nInputRows, nInputCols, kH, kW, dH, dW);
  }

  // clean
  THCudaTensor_free(state, input);

  // check for errors
  cudaError_t err = cudaGetLastError();
  if (err != cudaSuccess) {
    printf("error in SpatialMaxsampling.updateOutput: %s\n", cudaGetErrorString(err));
    THError("aborting");
  }
}


void SpatialMaxPooling_updateGradInput(THCState* state, THCudaTensor* input,
    THCudaTensor* gradInput, THCudaTensor* gradOutput, THCudaTensor* indices, int kW, int kH, int dW, int dH)
{
  bool atomic = (dW != kW) || (dH != kH); 

  float *indices_data;
  float *gradInput_data;
  float *gradOutput_data;

  if (input->nDimension == 3) {
    long nInputCols = input->size[2];
    long nInputRows = input->size[1];
    long nInputPlane = input->size[0];
    long nOutputCols = gradOutput->size[2];
    long nOutputRows = gradOutput->size[1];

    THCudaTensor_resizeAs(state, gradInput, input);
    THCudaTensor_zero(state, gradInput);

    indices_data = THCudaTensor_data(state, indices);
    gradOutput_data = THCudaTensor_data(state, gradOutput);
    gradInput_data = THCudaTensor_data(state, gradInput);

    // cuda blocks & threads:
    int yblocks = (int)(16L / nInputPlane);
    yblocks = yblocks < 1 ? 1 : yblocks;
    dim3 blocks(nInputPlane,yblocks);
    dim3 threads(32,8);

    if(atomic)
    {
      // run updateGradInput kernel, accumulate gradients atomically
      atomicmaxgradinput <<<blocks, threads>>> (gradInput_data, gradOutput_data, 
                                          indices_data+nInputPlane*nOutputCols*nOutputRows, indices_data,
                                          nInputPlane, nInputRows, nInputCols, kH, kW, dH, dW);
    }
    else
    {
      // run updateGradInput kernel
      atomicmaxgradinput <<<blocks, threads>>> (gradInput_data, gradOutput_data, 
                                          indices_data+nInputPlane*nOutputCols*nOutputRows, indices_data,
                                          nInputPlane, nInputRows, nInputCols, kH, kW, dH, dW);
    }
  } else {
    long nInputCols = input->size[3];
    long nInputRows = input->size[2];
    long nInputPlane = input->size[1];
    long nbatch = input->size[0];
    long nOutputCols = gradOutput->size[3];
    long nOutputRows = gradOutput->size[2];

    THCudaTensor_resizeAs(state, gradInput, input);
    THCudaTensor_zero(state, gradInput);

    indices_data = THCudaTensor_data(state, indices);
    gradOutput_data = THCudaTensor_data(state, gradOutput);
    gradInput_data = THCudaTensor_data(state, gradInput);

    // cuda blocks & threads:
    int yblocks = (int)(16L / nInputPlane);
    yblocks = yblocks < 1 ? 1 : yblocks;
    dim3 blocks(nInputPlane*nbatch,yblocks);
    dim3 threads(32,8);

    if(atomic)
    {
      // run updateGradInput kernel, accumulate gradients atomically
      atomicmaxgradinput <<<blocks, threads>>> (gradInput_data, gradOutput_data,
                                          indices_data+nbatch*nInputPlane*nOutputCols*nOutputRows, indices_data,
                                          nInputPlane, nInputRows, nInputCols, kH, kW, dH, dW);
    }
    else
    {
      // run updateGradInput kernel, accumulate gradients atomically
      maxgradinput <<<blocks, threads>>> (gradInput_data, gradOutput_data,
                                          indices_data+nbatch*nInputPlane*nOutputCols*nOutputRows, indices_data,
                                          nInputPlane, nInputRows, nInputCols, kH, kW, dH, dW);
    }
  }

  // check for errors
  cudaError_t err = cudaGetLastError();
  if (err != cudaSuccess) {
    printf("error in SpatialMaxsampling.updateGradInput: %s\n", cudaGetErrorString(err));
    THError("aborting");
  }
}

#undef CUDA_MAX_THREADS
