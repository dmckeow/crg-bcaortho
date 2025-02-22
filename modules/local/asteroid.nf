process ASTEROID {
    tag "Asteroid"
    label 'process_asteroid'

    container "${ workflow.containerEngine == 'docker' ? 'arcadiascience/asteroid_3aae117d-disco_20e10c33:1.0.0':
        workflow.containerEngine == 'apptainer' ? 'arcadiascience/asteroid_3aae117d-disco_20e10c33:1.0.0':
        '' }"

    publishDir(
        path: "${params.outdir}/${publish_subdir}/asteroid",
        mode: params.publish_dir_mode,
        saveAs: { fn -> fn.substring(fn.lastIndexOf('/')+1) },
    )

    input:
    val species_names  // Names of all species
    file treefiles     // Filepath to the asteroid treefile (all newick gene trees)
    val outgroups      // String of specified outgroups to root species tree with, if provided
    val publish_subdir

    output:
    path "asteroid.bestTree.newick"        , emit: spp_tree
    path "asteroid_rooted.bestTree.newick" , emit: rooted_spp_tree, optional: true
    path "*allTrees.newick"                , emit: all_asteroid_trees
    path "*bsTrees.newick"                 , emit: asteroid_bs_trees
    path "*scores.txt"                     , emit: asteroid_scores
    path "disco*.newick"                   , emit: disco_trees
    
    when:
    task.ext.when == null || task.ext.when

    // always gets set as the file itself, excluding the path
    script:
    def args = task.ext.args ?: ''
    """
    # Generate new protein names to more readily delimit species/protein ids
    echo "$species_names" | sed "s/\\[//g" | sed "s/\\]//g" | tr "," "\\n" > original_spp_names.txt
    sed "s/_/-/g" original_spp_names.txt | sed "s/ //g" > new_spp_names.txt
    paste original_spp_names.txt new_spp_names.txt > spp_rename.txt
    rm original_spp_names.txt new_spp_names.txt

    # Create the list of gene family trees to be decomposed into single-copy
    # trees using DISCO
    cat *.treefile >> gene_family_trees.newick

    # Use the updated species names to update protein names in these gene family
    # trees, ensuring that underscores in names successfully delimit protein ids
    # Combine these, and update names in the tree file to match these:
    while read spp
    do
        old=\$(echo \$spp | cut -f1 -d" ")
        new=\$(echo \$spp | cut -f2 -d" ")
        sed -i "s/\${old}/\${new}/g" gene_family_trees.newick
    done < spp_rename.txt

    # Run DISCO to decompose gene family trees into single-copy trees, rooted to
    # minimize the number of duplications and losses
    python /DISCO/disco.py \\
        -i gene_family_trees.newick \\
        -o disco_decomposed_rooted_gfts.newick \\
        -d "_"

    # Run asteroid using the multithreaded mpi version
    mpiexec -np ${task.cpus} --allow-run-as-root --use-hwthread-cpus \
    asteroid \
    -i disco_decomposed_rooted_gfts.newick \
    -p asteroid \
    $args

    # Now revert the species names back to their original values in all treefiles:
    while read spp
    do
        old=\$(echo \$spp | cut -f1 -d" ")
        new=\$(echo \$spp | cut -f2 -d" ")
        sed -i "s/\${new}/\${old}/g" *.newick
    done < spp_rename.txt

    # Lastly, reroot the tree if user-specified outgroups are provided
    if [[ $outgroups != "none" ]]; then
        reroot_speciestree.R asteroid.bestTree.newick $outgroups
    fi

    """
}
