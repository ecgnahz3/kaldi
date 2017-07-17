#!/bin/bash
# _1c is as _1b but it uses chain model to generate alignment for RM using SWJ model.
# _1b is as _1a but uses a src-tree-dir to convert target alignment and combine
# alignemts from source and target to train phone LM for den.fst in chain denominator graph.

# This script uses weight transfer as Transfer learning method
# and use already trained model on wsj and remove the last layer and
# add new randomly initialized layer and retrain the whole network.
# while training new added layer using rm data.
# The chain config is as run_tdnn_5n.sh and the result is:
#System tdnn_5n tdnn_wsj_rm
#WER      2.71     2.21
set -e

# configs for 'chain'
stage=8
train_stage=-10
get_egs_stage=-10
dir=exp/chain/tdnn_wsj_rm_1c

# training options
frames_per_chunk=150
num_epochs=2
initial_effective_lrate=0.005
final_effective_lrate=0.0005
leftmost_questions_truncate=-1
max_param_change=2.0
final_layer_normalize_target=0.5
num_jobs_initial=2
num_jobs_final=4
minibatch_size=32
frames_per_eg=150
remove_egs=false
xent_regularize=0.1

# configs for transfer learning
common_egs_dir=
srcdir=../../wsj/s5
src_mdl=$srcdir/exp/chain/tdnn1d_sp/final.mdl
src_lang=$srcdir/data/lang
src_tree_dir=$srcdir/exp/chain/tree_a_sp # chain tree-dir for src data;
                                         # the alignment in target domain is
                                         # converted using src-tree
primary_lr_factor=0.25 # learning-rate factor for all except last layer in transferred source model
final_lr_factor=1.0   # learning-rate factor for final affine layer in transferred source model.
nnet_affix=_online_wsj

# End configuration section.

echo "$0 $@"  # Print the command line for logging

. ./cmd.sh
. ./path.sh
. ./utils/parse_options.sh

if ! cuda-compiled; then
  cat <<EOF && exit 1
This script is intended to be used with GPUs but you have not compiled Kaldi with CUDA
If you want to use GPUs (and have them), go to src/, and configure and make on a machine
where "nvcc" is installed.
EOF
fi

# The iVector-extraction and feature-dumping parts are the same as the standard
# nnet3 setup, and you can skip them by setting "--stage 8" if you have already
# run those things.

lang=data/lang_chain_5n_wsj
lang_src_tgt=data/lang_wsj_rm
ali_dir=exp/chain/chain_ali_wsj
treedir=exp/chain/tri4_5n_tree_wsj
lat_dir=exp/chain_lats${src_tree_dir:+_wsj}

if [ $stage -le -1 ]; then
  echo "$0: prepare lang for RM-WSJ using WSJ phone set and lexicon and RM word list."
  if ! cmp -s <(grep -v "^#" $src_lang/phones.txt) <(grep -v "^#" data/lang/phones.txt); then
  local/prepare_wsj_rm_lang.sh  $srcdir/data/local/dict_nosp $src_lang $lang_dir
  else
    rm -rf $lang_dir
    cp -r data/lang $lang_dir
  fi
fi

local/online/run_nnet2_common.sh  --stage $stage \
                                  --ivector-dim 100 \
                                  --nnet-affix "$nnet_affix" \
                                  --mfcc-config $srcdir/conf/mfcc_hires.conf \
                                  --extractor $srcdir/exp/nnet3/extractor || exit 1;
src_mdl_dir=`dirname $src_mdl`
if [ $stage -le 4 ]; then
  echo "$0: Generate alignment using source chain model."
  scale_opts="--transition-scale=1.0 --acoustic-scale=1.0 --self-loop-scale=1.0"
  steps/nnet3/align.sh --nj 100 --cmd "$train_cmd" \
  --online-ivector-dir exp/nnet2${nnet_affix}/ivectors \
  --extra-left-context-initial 0 --extra-right-context-final 0 \
  --scale-opts "$scale_opts" \
  --frames-per-chunk $frames_per_chunk \
  data/train_hires $lang_src_tgt $src_mdl_dir $ali_dir || exit 1;
fi

chain_opts=(--chain.alignment-subsampling-factor=1 --chain.left-tolerance=1 --chain.right-tolerance=1)
if [ $stage -le 5 ]; then
  # Get the alignments as lattices (gives the chain training more freedom).
  # use the same num-jobs as the alignments
  scale_opts="--transition-scale=1.0 --self-loop-scale=1.0"
  nj=$(cat $ali_dir/num_jobs) || exit 1;
  steps/nnet3/align_lats.sh --nj $nj --cmd "$train_cmd" \
    --acoustic-scale 1.0 --extra-left-context-initial 0 --extra-right-context-final 0 \
    --frames-per-chunk $frames_per_chunk \
    --scale-opts "$scale_opts" \
    --online-ivector-dir exp/nnet2${nnet_affix}/ivectors data/train_hires \
    $lang_src_tgt $ali_dir $lat_dir || exit 1;
  rm $lat_dir/fsts.*.gz # save space
fi

if [ $stage -le 6 ]; then
  echo "$0: creating neural net configs using the xconfig parser and ";
  echo "generating $dir/configs/vars.";
  num_targets=$(tree-info $src_tree_dir/tree |grep num-pdfs|awk '{print $2}')
  mkdir -p $dir
  mkdir -p $dir/configs
  touch $dir/configs/network.xconfig
  steps/nnet3/xconfig_to_configs.py --existing-model $src_mdl \
    --xconfig-file  $dir/configs/network.xconfig  \
    --edits-config $dir/configs/edits.config \
    --config-dir $dir/configs/
fi

if [ $stage -le 7 ]; then
  echo "$0: generate egs for chain to train new model on rm dataset."
  if [[ $(hostname -f) == *.clsp.jhu.edu ]] && [ ! -d $dir/egs/storage ]; then
    utils/create_split_dir.pl \
     /export/b0{3,4,5,6}/$USER/kaldi-data/egs/rm-$(date +'%m_%d_%H_%M')/s5c/$dir/egs/storage $dir/egs/storage
  fi
  echo "$0: set the learning-rate-factor for initial network to be zero."
  $decode_cmd $dir/log/copy_mdl.log \
  nnet3-am-copy --raw=true --edits="set-learning-rate-factor name=* learning-rate-factor=$primary_lr_factor; set-learning-rate-factor name=output* learning-rate-factor=$final_lr_factor" \
    $src_mdl $dir/init.raw || exit 1;

  steps/nnet3/chain/train_more.py --stage $train_stage ${chain_opts[@]} \
    --cmd "$decode_cmd" \
    --feat.online-ivector-dir exp/nnet2${nnet_affix}/ivectors \
    --chain.xent-regularize $xent_regularize \
    --chain.alignments-for-lm="$ali_dir:10,$src_tree_dir:1" \
    --feat.cmvn-opts "--norm-means=false --norm-vars=false" \
    --chain.xent-regularize 0.1 \
    --chain.leaky-hmm-coefficient 0.1 \
    --chain.l2-regularize 0.00005 \
    --chain.apply-deriv-weights false \
    --chain.lm-opts="--num-extra-lm-states=200" \
    --egs.dir "$common_egs_dir" \
    --egs.opts "--frames-overlap-per-eg 0" \
    --egs.chunk-width $frames_per_eg \
    --trainer.num-chunk-per-minibatch=$minibatch_size \
    --trainer.frames-per-iter 1000000 \
    --trainer.num-epochs $num_epochs \
    --trainer.optimization.num-jobs-initial=$num_jobs_initial \
    --trainer.optimization.num-jobs-final=$num_jobs_final \
    --trainer.optimization.initial-effective-lrate=$initial_effective_lrate \
    --trainer.optimization.final-effective-lrate=$final_effective_lrate \
    --trainer.max-param-change $max_param_change \
    --cleanup.remove-egs false \
    --feat-dir data/train_hires \
    --tree-dir $src_tree_dir \
    --lat-dir $lat_dir \
    --dir $dir || exit 1;
fi

if [ $stage -le 8 ]; then
  steps/online/nnet2/extract_ivectors_online.sh --cmd "$train_cmd" --nj 4 \
    data/test_hires $srcdir/exp/nnet3/extractor exp/nnet2${nnet_affix}/ivectors_test || exit 1;
fi

if [ $stage -le 9 ]; then
  # Note: it might appear that this $lang directory is mismatched, and it is as
  # far as the 'topo' is concerned, but this script doesn't read the 'topo' from
  # the lang directory.
  utils/mkgraph.sh --self-loop-scale 1.0 $lang_src_tgt $dir $dir/graph
  steps/nnet3/decode.sh --acwt 1.0 --post-decode-acwt 10.0 \
    --scoring-opts "--min-lmwt 1" \
    --nj 20 --cmd "$decode_cmd" \
    --online-ivector-dir exp/nnet2${nnet_affix}/ivectors_test \
    $dir/graph data/test_hires $dir/decode || exit 1;
fi

if [ $stage -le 10 ]; then
  utils/mkgraph.sh --self-loop-scale 1.0 ${lang_src_tgt}_ug $dir $dir/graph_ug
  steps/nnet3/decode.sh --acwt 1.0 --post-decode-acwt 10.0 \
    --nj 20 --cmd "$decode_cmd" \
    --online-ivector-dir exp/nnet2${nnet_affix}/ivectors_test \
    $dir/graph_ug data/test_hires $dir/decode_ug || exit 1;
fi
wait;
exit 0;
