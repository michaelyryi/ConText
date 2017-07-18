#!/bin/bash
  ####  Input: token file (one review per line; tokens are delimited by white space): *.txt.tok
  ####         label file (one label per line): *.cat
  ####  These input files were generated by prep_imdb.sh and included in the package. 
  ####  To find the order of the data points, see prep_imdb.sh and the files at lst/. 

  #-----------------#
  gpu=-1  # <= change this to, e.g., "gpu=0" to use a specific GPU. 
  mem=2   # pre-allocate 2GB device memory. 
  source sh-common.sh
  #-----------------#
  nm=imdb; psz0=2; psz1=3; reg=1e-4
# nm=elec; psz0=3; psz1=4; reg=0  # <= Uncomment this to train/test on Elec 
  z=s2bn # To avoid filename conflict.
  x_ext=.xsmatcvar

  #---  Step 1. Generate vocabulary for NB weights
  echo Generaing uni-, bi-, and tri-gram vocabulary from training data to make NB-weights ... 
  options="LowerCase UTF8"
  voc123=${tmpdir}/${nm}${z}_trn-123gram.vocab
  rm -f $voc123
  for nn in 1 2 3; do
    vocab_fn=${tmpdir}/${nm}${z}_trn-${nn}gram.vocab  
    $prep_exe gen_vocab input_fn=data/${nm}-train.txt.tok vocab_fn=$vocab_fn \
        $options WriteCount n=$nn
    if [ $? != 0 ]; then echo $shnm: gen_vocab failed.; exit 1; fi
    cat $vocab_fn >> $voc123
  done 

  #---  Step 2-1. Generate NB-weights 
  echo Generating NB-weights ... 
  $prep_exe gen_nbw $options nbw_fn=${tmpdir}/${nm}${z}.nbw3.dmat \
       vocab_fn=$voc123 train_fn=data/${nm}-train label_dic_fn=data/${nm}_cat.dic
  if [ $? != 0 ]; then echo $shnm: gen_nbw failed.; exit 1; fi

  #---  Step 2-2.  Generate NB-weighted bag-of-ngram files ...
  echo; echo Generating NB-weighted bag-of-ngram files ... 
  for set in train test; do
    $prep_exe gen_nbwfeat $options vocab_fn=$voc123 input_fn=data/${nm}-${set} \
       output_fn_stem=${tmpdir}/${nm}${z}_${set}-nbw3 x_ext=$x_ext \
       label_dic_fn=data/${nm}_cat.dic nbw_fn=${tmpdir}/${nm}${z}.nbw3.dmat
    if [ $? != 0 ]; then echo $shnm: gen_nbwfeat failed.; exit 1; fi
  done

  #---  Step 3.  Generate vocabulty for CNN 
  echo; echo Generating vocabulary from training data for CNN ... 
  max_num=30000
  vocab_fn=${tmpdir}/${nm}${z}_trn-1gram.${max_num}.vocab  
  $prep_exe gen_vocab input_fn=data/${nm}-train.txt.tok vocab_fn=$vocab_fn max_vocab_size=$max_num \
            $options WriteCount
  if [ $? != 0 ]; then echo $shnm: gen_vocab failed.; exit 1; fi

  #---  Step 4. Generate region files (${tmpdir}/*.xsmatbcvar) and target files (${tmpdir}/*.y) for training and testing CNN.  
  #     We generate region vectors of the convolution layer and write them to a file, instead of making them 
  #     on the fly during training/testing. 
  echo; echo Generating region files ...
  for pch_sz in $psz0 $psz1; do
    for set in train test; do 
      rnm=${tmpdir}/${nm}${z}_${set}-p${pch_sz}
      $prep_exe gen_regions $options region_fn_stem=$rnm \
          input_fn=data/${nm}-${set} vocab_fn=$vocab_fn label_dic_fn=data/${nm}_cat.dic \
          x_ext=$x_ext patch_size=$pch_sz padding=$((pch_sz-1))
      if [ $? != 0 ]; then echo $shnm: gen_regions failed.; exit 1; fi
    done
  done

  #---  Step 5. Training and test using GPU
  mynm=shcnn-seq2-bown-${nm}
  log_fn=${logdir}/${mynm}.log; csv_fn=${csvdir}/${mynm}.csv
  echo; echo Training and testing ... ; echo This takes a while.  See $log_fn and $csv_fn for progress. 
  nodes0=20; nodes1=1000; nodes2=1000 # number of feature maps (weight vectors)
  $exe $gpu:$mem train datatype=sparse data_dir=$tmpdir trnname=${nm}${z}_train- tstname=${nm}${z}_test- \
         dsno0=nbw3 dsno1=p${psz0} dsno2=p${psz1} \
         x_ext=$x_ext \
         num_epochs=100 ss_scheduler=Few ss_decay=0.1 ss_decay_at=80 \
         loss=Square reg_L2=$reg top_reg_L2=1e-4 step_size=0.25 top_dropout=0.5 \
         momentum=0.9 mini_batch_size=100 random_seed=1 \
         layers=3 conn=0-top,1-top,2-top ConcatConn \
         0layer_type=Weight+ 1layer_type=Weight+ 2layer_type=Weight+ \
         0nodes=$nodes0  0dsno=0 \
         1nodes=$nodes1  1dsno=1 \
         2nodes=$nodes2  2dsno=2 \
         activ_type=Rect pooling_type=Max num_pooling=1 resnorm_type=Text \
         test_interval=25 evaluation_fn=$csv_fn > ${log_fn}
  if [ $? != 0 ]; then echo $shnm: training failed.; exit 1; fi

  rm -f ${tmpdir}/${nm}${z}*
