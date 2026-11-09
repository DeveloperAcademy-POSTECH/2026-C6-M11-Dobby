"""Convert the local pilot checkpoint and compare native Core ML predictions.

Requires coremltools 9, torch 2.7, torchvision 0.22, Pillow, numpy on macOS.
Does not train or upload images. Model source is the pilot training directory.
"""
import argparse, hashlib, json, sys
from pathlib import Path
import coremltools as ct
import numpy as np
from PIL import Image
import torch
from torch import nn

def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('--training-dir',type=Path,required=True)
    parser.add_argument('--output',type=Path,required=True)
    parser.add_argument('--report',type=Path,required=True)
    args=parser.parse_args();sys.path.insert(0,str(args.training_dir))
    from train import NeckModel, decode, MEAN, STD, W, H
    torch.set_num_threads(4)
    checkpoint_path=args.training_dir/'pilot-v1/best.pt'
    checkpoint=torch.load(checkpoint_path,map_location='cpu',weights_only=True)
    model=NeckModel(pretrained=False).eval();model.load_state_dict(checkpoint['state_dict'])
    class NormalizedModel(nn.Module):
        def __init__(self):
            super().__init__();self.model=model
            self.register_buffer('mean',MEAN[None]);self.register_buffer('std',STD[None])
        def forward(self,x):return self.model((x-self.mean)/self.std)
    wrapped=NormalizedModel().eval()
    traced=torch.jit.trace(wrapped,torch.rand(1,3,H,W))
    converted=ct.convert(traced,source='pytorch',convert_to='mlprogram',
        minimum_deployment_target=ct.target.iOS18,compute_precision=ct.precision.FLOAT32,
        inputs=[ct.ImageType(name='image',shape=(1,3,H,W),scale=1/255,color_layout=ct.colorlayout.RGB)],
        outputs=[ct.TensorType(name='heatmaps',dtype=np.float32)])
    converted.short_description='Dobby Luna-route image-left/right side neck pilot; 72 labeled jacket photos.'
    converted.version='neck-side-resnet18-pilot-v1-epoch44'
    converted.input_description['image']='Upright RGB garment raster resized directly to 256x448; internal per-channel ImageNet normalization.'
    converted.output_description['heatmaps']='Uncalibrated logits [1,2,112,64]; channel0=image-left neck, channel1=image-right neck. Decode 5x5 local soft argmax.'
    converted.user_defined_metadata['checkpoint_sha256']=hashlib.sha256(checkpoint_path.read_bytes()).hexdigest()
    converted.user_defined_metadata['annotation_sha256']=checkpoint['annotationSha256']
    converted.user_defined_metadata['limitations']='Pilot: no calibrated visibility; no Dobby camera-domain evaluation; validate mask and geometry before measurements.'
    args.output.parent.mkdir(parents=True,exist_ok=True);converted.save(str(args.output))
    dataset=json.loads((args.training_dir/'pilot-v1/dataset.json').read_text())
    rows=[]
    for split in ['val','test']:
        for r in dataset['splits'][split]:
            im=Image.open(args.training_dir.parent/r['image']).convert('RGB').rotate(-r['rotation'],expand=True).resize((W,H),Image.Resampling.BILINEAR)
            x=torch.from_numpy(np.array(im).copy()).permute(2,0,1).float()[None]/255
            with torch.no_grad():reference=wrapped(x);refpoints=decode(reference).numpy()[0]
            heatmap=converted.predict({'image':im})['heatmaps']
            points=decode(torch.from_numpy(heatmap.copy())).numpy()[0]
            delta=np.linalg.norm((points-refpoints)*[720,1280],axis=-1)
            rows.append({'id':r['id'],'split':split,'pytorch':refpoints.tolist(),'coreML':points.tolist(),
                         'maxLogitDifference':float(np.abs(heatmap-reference.numpy()).max()),'maxSourcePixelDrift':float(delta.max())})
    summary={'model':str(args.output),'checkpointSha256':converted.user_defined_metadata['checkpoint_sha256'],
             'precision':'float32','images':len(rows),'maxSourcePixelDrift':max(r['maxSourcePixelDrift'] for r in rows),'rows':rows}
    args.report.write_text(json.dumps(summary,indent=2));print(json.dumps({k:v for k,v in summary.items() if k!='rows'}),flush=True)
    assert summary['maxSourcePixelDrift']<.5, 'Core ML conversion moved a predicted point too far'

if __name__=='__main__':main()
